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
import ../core/debug

# ═══════════════════════════════════════════════════════════════════════════
# Multiboot1 Protocol Support
# ═══════════════════════════════════════════════════════════════════════════

# Multiboot1 magic numbers
const MULTIBOOT1_MAGIC_HEADER* = 0x1BADB002'u32
const MULTIBOOT1_MAGIC_BOOT*   = 0x2BADB002'u32

# Flags bits for multiboot_info_t
const
  MBI_MEMFLAGS     = 1'u32 shl 0  ## mem_lower / mem_upper valid
  MBI_BOOTDEV      = 1'u32 shl 1  ## boot_device valid
  MBI_CMDLINE      = 1'u32 shl 2  ## cmdline valid
  MBI_MODS         = 1'u32 shl 3  ## modules valid
  MBI_SYMS4        = 1'u32 shl 4  ## a.out symbol table valid
  MBI_SYMSELF      = 1'u32 shl 5  ## ELF section header table valid
  MBI_MEMMAP       = 1'u32 shl 6  ## memory map valid
  MBI_DRIVES       = 1'u32 shl 7  ## drives valid
  MBI_CONFIG       = 1'u32 shl 8  ## config table valid
  MBI_BOOTLDNAME   = 1'u32 shl 9  ## bootloader name valid
  MBI_APM          = 1'u32 shl 10 ## APM table valid
  MBI_VBE          = 1'u32 shl 11 ## VBE info valid
  MBI_FRAMEBUFFER  = 1'u32 shl 12 ## framebuffer info valid

type
  Multiboot1Info* = object
    ## Multiboot1 information structure (as provided by bootloader)
    flags*: uint32
    memLower*: uint32
    memUpper*: uint32
    bootDevice*: uint32
    cmdline*: uint32
    modsCount*: uint32
    modsAddr*: uint32
    syms: array[4, uint32]  # ELF / a.out symbol table
    mmapLength*: uint32
    mmapAddr*: uint32
    drivesLength*: uint32
    drivesAddr*: uint32
    configTable*: uint32
    bootLoaderName*: uint32
    apmTable*: uint32
    vbeControlInfo*: uint32
    vbeModeInfo*: uint32
    vbeMode*: uint16
    vbeInterfaceSeg*: uint16
    vbeInterfaceOff*: uint16
    vbeInterfaceLen*: uint16
    framebufferAddr*: uint64
    framebufferPitch*: uint32
    framebufferWidth*: uint32
    framebufferHeight*: uint32
    framebufferBpp*: uint8
    framebufferType*: uint8
    colorInfo: array[6, uint8]

  Multiboot1MmapEntry* = object
    ## Multiboot1 memory map entry (packed)
    size*: uint32          ## size of this entry (minus size field)
    baseAddr*: uint64      ## base address
    length*: uint64        ## length in bytes
    entryType*: uint32     ## 1 = available, 2 = reserved, etc.

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
    bpMultiboot1
    bpMultiboot2
    bpLimine

  BootloaderError* = enum
    beSuccess
    beInvalidMagic
    beInvalidTag
    beMemoryMapMissing
    beParseError
    beUnsupported

# ═══════════════════════════════════════════════════════════════════════════
# Multiboot1 Parsing
# ═══════════════════════════════════════════════════════════════════════════

proc parseMultiboot1*(infoPtr: pointer, bootInfo: var BootInfo): Result[void, BootloaderError] =
  ## Parse Multiboot1 boot information structure

  let mbi = cast[ptr Multiboot1Info](infoPtr)

  # Set boot protocol name
  for i in 0..<10:
    bootInfo.bootProtocol[i] = "Multiboot1"[i]

  # Parse memory map (if present)
  if (mbi.flags and MBI_MEMMAP) != 0 and mbi.mmapAddr != 0:
    var offset = 0'u32
    bootInfo.memoryMap.count = 0

    while offset < mbi.mmapLength and bootInfo.memoryMap.count < 64:
      let entry = cast[ptr Multiboot1MmapEntry](uint64(mbi.mmapAddr) + uint64(offset))
      let entrySize = if entry.size > 0: entry.size + 4'u32 else: 24'u32

      bootInfo.memoryMap.regions[bootInfo.memoryMap.count] = MemoryRegion(
        base: PhysAddr(entry.baseAddr),
        length: entry.length,
        regionType: case entry.entryType
          of 1: memAvailable
          of 3: memAcpiReclaimable
          of 4: memAcpiNvs
          of 5: memBadMemory
          else: memReserved
      )

      inc bootInfo.memoryMap.count
      offset += entrySize

    if bootInfo.memoryMap.count == 0:
      return err(beMemoryMapMissing)
  else:
    # No memory map; synthesize from mem_lower / mem_upper fields
    if (mbi.flags and MBI_MEMFLAGS) != 0:
      bootInfo.memoryMap.count = 2
      bootInfo.memoryMap.regions[0] = MemoryRegion(
        base: PhysAddr(0),
        length: uint64(mbi.memLower) * 1024,
        regionType: memAvailable
      )
      bootInfo.memoryMap.regions[1] = MemoryRegion(
        base: PhysAddr(1 * MiB),
        length: uint64(mbi.memUpper) * 1024,
        regionType: memAvailable
      )
    else:
      return err(beMemoryMapMissing)

  # Parse command line
  if (mbi.flags and MBI_CMDLINE) != 0 and mbi.cmdline != 0:
    let cmdPtr = cast[cstring](uint64(mbi.cmdline))
    var i = 0
    while i < 255 and cmdPtr[i] != '\0':
      bootInfo.cmdline[i] = cmdPtr[i]
      inc i
    bootInfo.cmdlineLen = i

  ok()

# ═══════════════════════════════════════════════════════════════════════════
# Detection & Parsing
# ═══════════════════════════════════════════════════════════════════════════

proc detectProtocol*(magicReg: uint32, infoPtr: pointer): BootloaderProtocol =
  ## Detect bootloader protocol from magic number
  ##
  ## Multiboot1: magic = 0x2BADB002 in EAX at entry
  ## Multiboot2: magic = 0x36d76289 in EAX at entry
  case magicReg
  of MULTIBOOT1_MAGIC_BOOT:
    return bpMultiboot1
  of MULTIBOOT2_MAGIC:
    return bpMultiboot2
  else:
    return bpUnknown

proc nextTag*(current: pointer, tagSize: uint32): pointer {.inline.} =
  ## Get pointer to next tag (accounting for 8-byte alignment)
  let aligned = alignUp(uint64(tagSize), 8)
  cast[pointer](cast[uint64](current) + aligned)

proc parseMultiboot2MemoryMap*(tag: pointer, bootInfo: var BootInfo): Result[void, BootloaderError] =
  ## Parse Multiboot2 memory map tag
  let mmTag = cast[ptr Multiboot2MemoryMapTag](tag)

  if mmTag.entrySize < uint32(sizeof(Multiboot2MemoryMapEntry)):
    return err(beInvalidTag)

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
  ##
  ## Multiboot2 info structure layout:
  ##   offset 0: total_size (uint32) — total size of the info structure
  ##   offset 4: reserved   (uint32)
  ##   offset 8: first tag  ...
  ##
  ## We use total_size as a hard bound for tag traversal, and also
  ## cap the number of tags to prevent infinite loops on corrupt data.

  earlyPutString("[MB2] Entered parseMultiboot2\n")
  let basePtr = cast[uint64](bootInfoPtr)

  # ── Read total_size from the Multiboot2 info header ─────────────
  earlyPutString("[MB2] Reading total_size...\n")
  let totalSizePtr = cast[ptr uint32](bootInfoPtr)
  let totalSize = totalSizePtr[]
  let endPtr = basePtr + uint64(totalSize)

  earlyPutString("[MB2] total_size = ")
  earlyPutHex(uint64(totalSize))
  earlyPutString("\n")

  # ── First tag starts at offset 8 ────────────────────────────────
  var tagPtr = basePtr + 8
  var tagCount = 0

  # Validate: total_size must be at least 16 (header + end tag)
  if totalSize < 16:
    earlyPutString("[MB2] ERROR: total_size too small: ")
    earlyPutHex(uint64(totalSize))
    earlyPutString("\n")
    return err(beInvalidTag)

  earlyPutString("[MB2] total_size OK, endPtr = ")
  earlyPutHex(endPtr)
  earlyPutString("\n")

  # Initialize defaults
  earlyPutString("[MB2] Init defaults...\n")
  for i in 0..31:
    bootInfo.bootProtocol[i] = '\0'
  for i in 0..9:
    bootInfo.bootProtocol[i] = "Multiboot2"[i]
  bootInfo.memoryMap.count = 0
  bootInfo.hasFramebuffer = false
  bootInfo.hasRsdp = false
  bootInfo.moduleCount = 0

  earlyPutString("[MB2] Init done, starting tag loop...\n")

  var foundMemoryMap = false

  while tagPtr < endPtr:
    let tag = cast[ptr Multiboot2Tag](tagPtr)

    # ── Safety: prevent infinite loop on corrupt data ──────────────
    tagCount += 1
    if tagCount > 128:
      earlyPutString("[MB2] ERROR: too many tags (>128), aborting\n")
      return err(beInvalidTag)

    # ── Debug: print each tag header ────────────────────────────────
    earlyPutString("[MB2] Tag #")
    earlyPutInt(int64(tagCount))
    earlyPutString(": ptr=")
    earlyPutHex(tagPtr)
    earlyPutString(" type=")
    earlyPutHex(uint64(tag.tagType))
    earlyPutString(" size=")
    earlyPutHex(uint64(tag.size))
    earlyPutString("\n")

    # ── End tag ────────────────────────────────────────────────────
    if tag.tagType == uint32(mbTagEnd):
      # Verify end tag is within bounds
      if tagPtr + 8 > endPtr:
        earlyPutString("[MB2] ERROR: end tag past total_size\n")
        return err(beInvalidTag)
      break

    # ── Validate minimum tag size ──────────────────────────────────
    if tag.size < 8:
      earlyPutString("[MB2] ERROR: tag size < 8: type=")
      earlyPutHex(uint64(tag.tagType))
      earlyPutString(" size=")
      earlyPutHex(uint64(tag.size))
      earlyPutString("\n")
      return err(beInvalidTag)

    # ── Validate tag fits within total_size ────────────────────────
    let nextPtr = cast[uint64](nextTag(cast[pointer](tagPtr), tag.size))
    if nextPtr > endPtr:
      earlyPutString("[MB2] ERROR: tag extends past total_size: type=")
      earlyPutHex(uint64(tag.tagType))
      earlyPutString(" size=")
      earlyPutHex(uint64(tag.size))
      earlyPutString(" next=")
      earlyPutHex(nextPtr)
      earlyPutString(" end=")
      earlyPutHex(endPtr)
      earlyPutString("\n")
      return err(beInvalidTag)

    # ── Debug: print tag info ──────────────────────────────────────
    # earlyDumpMultiboot2Tag(cast[pointer](tagPtr), tagCount - 1)

    # ── Parse known tag types ──────────────────────────────────────
    case Multiboot2TagType(tag.tagType)
    of mbTagMemoryMap:
      let res = parseMultiboot2MemoryMap(cast[pointer](tagPtr), bootInfo)
      if res.isOk:
        foundMemoryMap = true
        earlyPutString("[MB2] Parsed memory map: ")
        earlyPutInt(int64(bootInfo.memoryMap.count))
        earlyPutString(" regions\n")
      else:
        earlyPutString("[MB2] WARN: memory map parse failed\n")
    of mbTagFramebuffer:
      discard parseMultiboot2Framebuffer(cast[pointer](tagPtr), bootInfo)
      earlyPutString("[MB2] Parsed framebuffer\n")
    of mbTagCmdline:
      discard parseMultiboot2Cmdline(cast[pointer](tagPtr), bootInfo)
      let cmdStr = cast[cstring](tagPtr + uint64(sizeof(Multiboot2CmdlineTag)))
      earlyPutString("[MB2] Cmdline: ")
      earlyPutString(cmdStr)
      earlyPutString("\n")
    of mbTagRsdp:
      discard parseMultiboot2Rsdp(cast[pointer](tagPtr), bootInfo)
      earlyPutString("[MB2] Parsed RSDP\n")
    of mbTagBootLoaderName:
      let nameStr = cast[cstring](tagPtr + uint64(sizeof(Multiboot2Tag)))
      earlyPutString("[MB2] Bootloader: ")
      earlyPutString(nameStr)
      earlyPutString("\n")
    else:
      # Skip unknown tags
      earlyPutString("[MB2] Skipping tag type=")
      earlyPutHex(uint64(tag.tagType))
      earlyPutString("\n")

    # Move to next tag (8-byte aligned)
    tagPtr = nextPtr

  # Validate that we found a memory map
  if not foundMemoryMap:
    earlyPutString("[MB2] ERROR: no memory map tag found\n")
    return err(beMemoryMapMissing)

  earlyPutString("[MB2] Parsing complete: ")
  earlyPutInt(int64(tagCount))
  earlyPutString(" tags, ")
  earlyPutInt(int64(bootInfo.memoryMap.count))
  earlyPutString(" regions\n")

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
  of bpMultiboot1:
    return parseMultiboot1(infoPtr, bootInfo)
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
