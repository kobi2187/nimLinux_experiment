# SPDX-License-Identifier: GPL-2.0
## Boot Information - LAYER 1
##
## Common boot information structure populated by bootloader

import ../../core/types

type
  # ═══════════════════════════════════════════════════════════════════════════
  # Memory Map
  # ═══════════════════════════════════════════════════════════════════════════

  MemoryRegionType* = enum
    ## Type of memory region
    memAvailable     ## Usable RAM
    memReserved      ## Reserved by firmware
    memAcpiReclaimable  ## ACPI tables (reclaimable)
    memAcpiNvs       ## ACPI NVS memory
    memBadMemory     ## Bad/unusable memory
    memKernel        ## Kernel code/data
    memBootloader    ## Bootloader data
    memFramebuffer   ## Framebuffer memory

  MemoryRegion* = object
    ## Memory map entry
    base*: PhysAddr          ## Base address
    length*: uint64          ## Length in bytes
    regionType*: MemoryRegionType  ## Region type

  MemoryMap* = object
    ## Complete memory map
    regions*: array[64, MemoryRegion]  ## Memory regions
    count*: int                        ## Number of valid regions

  # ═══════════════════════════════════════════════════════════════════════════
  # Framebuffer Information
  # ═══════════════════════════════════════════════════════════════════════════

  PixelFormat* = enum
    ## Framebuffer pixel format
    pfIndexed   ## Indexed color palette
    pfRgb       ## RGB (red at lowest address)
    pfBgr       ## BGR (blue at lowest address)
    pfBitmask   ## Custom bitmask

  FramebufferInfo* = object
    ## Framebuffer information
    address*: PhysAddr       ## Framebuffer physical address
    width*: uint32           ## Width in pixels
    height*: uint32          ## Height in pixels
    pitch*: uint32           ## Bytes per row
    bpp*: uint8              ## Bits per pixel
    pixelFormat*: PixelFormat
    redMask*: uint32         ## Red channel mask
    greenMask*: uint32       ## Green channel mask
    blueMask*: uint32        ## Blue channel mask
    redShift*: uint8
    greenShift*: uint8
    blueShift*: uint8

  # ═══════════════════════════════════════════════════════════════════════════
  # ACPI Information
  # ═══════════════════════════════════════════════════════════════════════════

  RsdpInfo* = object
    ## ACPI RSDP location
    address*: PhysAddr       ## RSDP physical address
    revision*: uint8         ## ACPI revision (0 = 1.0, 2 = 2.0+)

  # ═══════════════════════════════════════════════════════════════════════════
  # Kernel Module
  # ═══════════════════════════════════════════════════════════════════════════

  Module* = object
    ## Loaded kernel module/initrd
    base*: PhysAddr          ## Module base address
    length*: uint64          ## Module size
    name*: array[64, char]   ## Module name/cmdline

  # ═══════════════════════════════════════════════════════════════════════════
  # Boot Information
  # ═══════════════════════════════════════════════════════════════════════════

  BootInfo* = object
    ## Complete boot information from bootloader
    # Memory
    memoryMap*: MemoryMap           ## Physical memory map
    totalMemory*: uint64            ## Total available memory

    # Framebuffer
    hasFramebuffer*: bool
    framebuffer*: FramebufferInfo

    # ACPI
    hasRsdp*: bool
    rsdp*: RsdpInfo

    # Command line
    cmdline*: array[256, char]
    cmdlineLen*: int

    # Kernel location
    kernelPhysBase*: PhysAddr       ## Kernel physical base
    kernelPhysEnd*: PhysAddr        ## Kernel physical end
    kernelVirtBase*: VirtAddr       ## Kernel virtual base

    # Modules (initrd, etc.)
    modules*: array[8, Module]
    moduleCount*: int

    # Boot protocol
    bootProtocol*: array[32, char]  ## e.g., "Limine", "Multiboot2"

    # SMP info
    cpuCount*: int                  ## Number of CPUs
    bspLapicId*: uint32             ## BSP LAPIC ID

# ═══════════════════════════════════════════════════════════════════════════
# Helper Functions
# ═══════════════════════════════════════════════════════════════════════════

proc getTotalMemory*(info: BootInfo): uint64 =
  ## Calculate total available memory from memory map
  result = 0
  for i in 0..<info.memoryMap.count:
    if info.memoryMap.regions[i].regionType == memAvailable:
      result += info.memoryMap.regions[i].length

proc getHighestAddress*(info: BootInfo): PhysAddr =
  ## Get highest physical address
  result = PhysAddr(0)
  for i in 0..<info.memoryMap.count:
    let endAddr = info.memoryMap.regions[i].base + info.memoryMap.regions[i].length
    if endAddr > result:
      result = endAddr

proc getCmdline*(info: BootInfo): string =
  ## Get command line as string
  result = newString(info.cmdlineLen)
  for i in 0..<info.cmdlineLen:
    result[i] = info.cmdline[i]

proc findRegion*(info: BootInfo, addr: PhysAddr): Option[MemoryRegion] =
  ## Find memory region containing address
  for i in 0..<info.memoryMap.count:
    let region = info.memoryMap.regions[i]
    if addr >= region.base and addr < region.base + region.length:
      return some(region)
  return none(MemoryRegion)

proc isUsable*(region: MemoryRegion): bool {.inline.} =
  region.regionType == memAvailable
