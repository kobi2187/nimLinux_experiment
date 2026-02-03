# SPDX-License-Identifier: GPL-2.0
## Bootloader Interface - LAYER 0/1
##
## Protocol-agnostic bootloader interface
## Supports: Multiboot2, Limine
##
## This is a component that:
## - Parses bootloader structures
## - Validates boot information
## - Populates BootInfo from raw bootloader data
## - Abstracts away bootloader protocol details

import ../core/types
import ../arch/common/boot_info

# ═══════════════════════════════════════════════════════════════════════════
# Multiboot2 Protocol Support
# ═══════════════════════════════════════════════════════════════════════════

# Multiboot2 magic number for validation
const MULTIBOOT2_MAGIC* = 0x36d76289'u32

# Multiboot2 tag types
type
  Multiboot2TagType* = enum
    mbTagEnd = 0
    mbTagCmdline = 1
    mbTagBootLoaderName = 2
    mbTagModule = 3
    mbTagMemoryInfo = 4
    mbTagBootDevice = 5
    mbTagMemoryMap = 6
    mbTagVbeInfo = 7
    mbTagFramebuffer = 8
    mbTagElfSections = 9
    mbTagApm = 10
    mbTagEfi32 = 11
    mbTagEfi64 = 12
    mbTagSmbios = 13
    mbTagAcpi1 = 14
    mbTagAcpi2 = 15
    mbTagNetworks = 16
    mbTagRsdp = 17
    mbTagEfiMemoryMap = 18
    mbTagEfiBootServices = 19
    mbTagEfi32ImageHandle = 20
    mbTagEfi64ImageHandle = 21

# Multiboot2 structures
type
  Multiboot2Header* = object
    magic*: uint32
    architecture*: uint32  # 0 = i386, 4 = mips32, etc.
    headerLength*: uint32
    checksum*: uint32

  Multiboot2Tag* = object
    tagType*: uint32
    size*: uint32
    # Data follows

  Multiboot2MemoryInfoTag* = object
    tagType*: uint32
    size*: uint32
    memLower*: uint32  # KB below 1MB
    memUpper*: uint32  # KB above 1MB

  Multiboot2MemoryMapTag* = object
    tagType*: uint32
    size*: uint32
    entrySize*: uint32
    entryVersion*: uint32
    # Entries follow

  Multiboot2MemoryMapEntry* = object
    base*: uint64
    length*: uint64
    entryType*: uint32  # 1 = available, 3 = ACPI, etc.
    reserved*: uint32

  Multiboot2FramebufferTag* = object
    tagType*: uint32
    size*: uint32
    framebufferAddr*: uint64
    framebufferPitch*: uint32
    framebufferWidth*: uint32
    framebufferHeight*: uint32
    framebufferBpp*: uint8
    framebufferType*: uint8
    reserved*: uint8
    # Color info follows (variable)

  Multiboot2RsdpTag* = object
    tagType*: uint32
    size*: uint32
    rsdp*: uint64  # Pointer to RSDP

  Multiboot2CmdlineTag* = object
    tagType*: uint32
    size*: uint32
    # Null-terminated string follows

  Multiboot2BootloaderNameTag* = object
    tagType*: uint32
    size*: uint32
    # Null-terminated string follows

# ═══════════════════════════════════════════════════════════════════════════
# Bootloader Protocol Detection
# ═══════════════════════════════════════════════════════════════════════════

type
  BootloaderProtocol* = enum
    bpUnknown
    bpMultiboot2
    bpLimine

  BootloaderError* = enum
    beSuccess
    beInvalidMagic
    beInvalidTag
    beMemoryMapMissing
    beParseError
    beUnsupported

# Convenience functions for BootloaderError results
proc ok*(): Result[void, BootloaderError] {.inline.} =
  Result[void, BootloaderError](isOk: true)

proc err*(e: BootloaderError): Result[void, BootloaderError] {.inline.} =
  Result[void, BootloaderError](isOk: false, error: e)

# ═══════════════════════════════════════════════════════════════════════════
# Detection & Parsing
# ═══════════════════════════════════════════════════════════════════════════

proc detectProtocol*(magicReg: uint32, infoPtr: pointer): BootloaderProtocol =
  ## Detect bootloader protocol from magic number
  ##
  ## Multiboot2: magic = 0x36d76289 in EAX at entry
  case magicReg
  of MULTIBOOT2_MAGIC:
    return bpMultiboot2
  else:
    return bpUnknown

proc alignUp*(value: uint64, alignment: uint64): uint64 {.inline.} =
  ## Align value up to alignment boundary
  ((value + alignment - 1) div alignment) * alignment

proc nextTag*(current: pointer, tagSize: uint32): pointer {.inline.} =
  ## Get pointer to next tag (accounting for 8-byte alignment)
  let aligned = alignUp(uint64(tagSize), 8)
  cast[pointer](cast[uint64](current) + aligned)

proc parseMultiboot2MemoryMap*(tag: pointer, bootInfo: var BootInfo): Result[void, BootloaderError] =
  ## Parse Multiboot2 memory map tag
  let mmTag = cast[ptr Multiboot2MemoryMapTag](tag)

  if mmTag.entrySize < uint32(sizeof(Multiboot2MemoryMapEntry)):
    return err[void, BootloaderError](beInvalidTag)

  bootInfo.memoryMap.count = 0
  var offset = sizeof(Multiboot2MemoryMapTag)
  var entryPtr = cast[uint64](tag) + uint64(offset)

  while offset < int(mmTag.size) and bootInfo.memoryMap.count < 64:
    let entry = cast[ptr Multiboot2MemoryMapEntry](entryPtr)

    bootInfo.memoryMap.regions[bootInfo.memoryMap.count] = MemoryRegion(
      base: PhysAddr(entry.base),
      length: entry.length,
      regionType: case entry.entryType
        of 1: memAvailable
        of 3: memAcpiReclaimable
        of 4: memAcpiNvs
        of 5: memBadMemory
        else: memReserved
    )

    inc bootInfo.memoryMap.count
    offset += int(mmTag.entrySize)
    entryPtr += uint64(mmTag.entrySize)

  if bootInfo.memoryMap.count == 0:
    return err(beMemoryMapMissing)

  ok()

proc parseMultiboot2Framebuffer*(tag: pointer, bootInfo: var BootInfo): Result[void, BootloaderError] =
  ## Parse Multiboot2 framebuffer tag
  let fbTag = cast[ptr Multiboot2FramebufferTag](tag)

  bootInfo.hasFramebuffer = true
  bootInfo.framebuffer = FramebufferInfo(
    address: PhysAddr(fbTag.framebufferAddr),
    width: fbTag.framebufferWidth,
    height: fbTag.framebufferHeight,
    pitch: fbTag.framebufferPitch,
    bpp: fbTag.framebufferBpp,
    pixelFormat: case fbTag.framebufferType
      of 0: pfIndexed  # Indexed color - not in current enum, use pfRgb as fallback
      of 1: pfRgb
      of 2: pfBgr
      else: pfRgb
  )

  ok()

proc parseMultiboot2Cmdline*(tag: pointer, bootInfo: var BootInfo): Result[void, BootloaderError] =
  ## Parse Multiboot2 command line tag
  let cmdTag = cast[ptr Multiboot2CmdlineTag](tag)
  let cmdPtr = cast[cstring](cast[uint64](tag) + uint64(sizeof(Multiboot2CmdlineTag)))

  bootInfo.cmdlineLen = 0
  var i = 0
  while i < 255 and cmdPtr[i] != '\0':
    bootInfo.cmdline[i] = cmdPtr[i]
    inc i
    inc bootInfo.cmdlineLen

  ok()

proc parseMultiboot2Rsdp*(tag: pointer, bootInfo: var BootInfo): Result[void, BootloaderError] =
  ## Parse Multiboot2 RSDP tag
  let rsdpTag = cast[ptr Multiboot2RsdpTag](tag)

  bootInfo.hasRsdp = true
  bootInfo.rsdp.address = PhysAddr(rsdpTag.rsdp)
  bootInfo.rsdp.revision = 2  # Multiboot2 provides RSDP 2.0

  ok()

proc parseMultiboot2*(bootInfoPtr: pointer, bootInfo: var BootInfo): Result[void, BootloaderError] =
  ## Parse Multiboot2 boot information
  ##
  ## Bootloader provides pointer to multiboot2 information structure
  ## Structure is a sequence of tags ending with TAG_TYPE_END

  let basePtr = cast[uint64](bootInfoPtr)
  var tagPtr = basePtr + 8  # Skip the checksum field at offset 0

  # Initialize defaults
  bootInfo.bootProtocol[0..31] = [0.char]
  for i in 0..31:
    if i < 10:
      bootInfo.bootProtocol[i] = "Multiboot2"[i]
  bootInfo.memoryMap.count = 0
  bootInfo.hasFramebuffer = false
  bootInfo.hasRsdp = false
  bootInfo.moduleCount = 0

  # Parse tags
  var foundMemoryMap = false

  while true:
    let tag = cast[ptr Multiboot2Tag](tagPtr)

    if tag.tagType == uint32(mbTagEnd):
      break

    # Minimum tag size is 8 bytes
    if tag.size < 8:
      return err(beInvalidTag)

    case Multiboot2TagType(tag.tagType)
    of mbTagMemoryMap:
      discard parseMultiboot2MemoryMap(cast[pointer](tagPtr), bootInfo)
      foundMemoryMap = true
    of mbTagFramebuffer:
      discard parseMultiboot2Framebuffer(cast[pointer](tagPtr), bootInfo)
    of mbTagCmdline:
      discard parseMultiboot2Cmdline(cast[pointer](tagPtr), bootInfo)
    of mbTagRsdp:
      discard parseMultiboot2Rsdp(cast[pointer](tagPtr), bootInfo)
    of mbTagBootLoaderName:
      # Could parse bootloader name here
      discard
    else:
      # Skip unknown tags
      discard

    # Move to next tag (8-byte aligned)
    tagPtr = cast[uint64](nextTag(cast[pointer](tagPtr), tag.size))

  if not foundMemoryMap:
    return err(beMemoryMapMissing)

  ok()

# ═══════════════════════════════════════════════════════════════════════════
# Public API
# ═══════════════════════════════════════════════════════════════════════════

proc parseBootInfo*(magicReg: uint32, infoPtr: pointer, bootInfo: var BootInfo): Result[void, BootloaderError] =
  ## Parse boot information from bootloader
  ##
  ## Call this early in kernel initialization with:
  ## - magicReg: Magic number from EAX at kernel entry
  ## - infoPtr: Pointer from EBX at kernel entry
  ## - bootInfo: Output structure to populate

  let protocol = detectProtocol(magicReg, infoPtr)

  case protocol
  of bpMultiboot2:
    return parseMultiboot2(infoPtr, bootInfo)
  of bpLimine:
    return err(beUnsupported)  # Not yet implemented
  of bpUnknown:
    return err(beInvalidMagic)

proc bootErrorToString*(error: BootloaderError): string =
  ## Convert boot error to human-readable string
  case error
  of beSuccess:
    return "Success"
  of beInvalidMagic:
    return "Invalid bootloader magic number"
  of beInvalidTag:
    return "Invalid bootloader tag"
  of beMemoryMapMissing:
    return "Memory map not provided by bootloader"
  of beParseError:
    return "Error parsing bootloader information"
  of beUnsupported:
    return "Bootloader protocol not yet supported"

proc validateBootInfo*(bootInfo: BootInfo): Result[void, BootloaderError] =
  ## Validate boot information completeness

  # Memory map is mandatory
  if bootInfo.memoryMap.count == 0:
    return err(beMemoryMapMissing)

  # At least 1 MB of memory
  if bootInfo.getTotalMemory() < 1024 * 1024:
    return err(beParseError)

  ok()
