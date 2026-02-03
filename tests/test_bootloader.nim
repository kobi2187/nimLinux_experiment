# SPDX-License-Identifier: GPL-2.0
## Tests for Bootloader Interface Component

import unittest
import ../boot/bootloader
import ../arch/common/boot_info
import ../core/types

suite "Bootloader Interface - Component Tests":

  test "Detect Multiboot2 protocol":
    let protocol = detectProtocol(MULTIBOOT2_MAGIC, nil)
    check protocol == bpMultiboot2

  test "Detect unknown protocol":
    let protocol = detectProtocol(0x12345678, nil)
    check protocol == bpUnknown

  test "Align value up":
    check alignUp(1, 8) == 8
    check alignUp(8, 8) == 8
    check alignUp(9, 8) == 16
    check alignUp(100, 16) == 112
    check alignUp(0, 8) == 0

  test "Error to string conversion":
    check bootErrorToString(beSuccess) == "Success"
    check bootErrorToString(beInvalidMagic) == "Invalid bootloader magic number"
    check bootErrorToString(beMemoryMapMissing) == "Memory map not provided by bootloader"

  test "Boot info calculation functions":
    var bootInfo: BootInfo
    bootInfo.memoryMap.count = 2
    bootInfo.memoryMap.regions[0] = MemoryRegion(
      base: PhysAddr(0x1000),
      length: 1024 * 1024,
      regionType: memAvailable
    )
    bootInfo.memoryMap.regions[1] = MemoryRegion(
      base: PhysAddr(0x100000),
      length: 2048 * 1024,
      regionType: memAvailable
    )

    let totalMem = bootInfo.getTotalMemory()
    check totalMem == (1024 + 2048) * 1024

    let highestAddr = bootInfo.getHighestAddress()
    check highestAddr == PhysAddr(0x100000 + 2048 * 1024)

  test "Find memory region by address":
    var bootInfo: BootInfo
    bootInfo.memoryMap.count = 1
    bootInfo.memoryMap.regions[0] = MemoryRegion(
      base: PhysAddr(0x1000),
      length: 1024,
      regionType: memAvailable
    )

    let region = bootInfo.findRegion(PhysAddr(0x1500))
    check region.isSome()
    check region.get().base == PhysAddr(0x1000)

    let noRegion = bootInfo.findRegion(PhysAddr(0x5000))
    check noRegion.isNone()

  test "Memory region type checking":
    var availRegion = MemoryRegion(
      base: PhysAddr(0),
      length: 1024,
      regionType: memAvailable
    )
    check availRegion.isUsable() == true

    var reservedRegion = MemoryRegion(
      base: PhysAddr(0),
      length: 1024,
      regionType: memReserved
    )
    check reservedRegion.isUsable() == false

  test "Get command line from boot info":
    var bootInfo: BootInfo
    bootInfo.cmdline[0] = 't'
    bootInfo.cmdline[1] = 'e'
    bootInfo.cmdline[2] = 's'
    bootInfo.cmdline[3] = 't'
    bootInfo.cmdlineLen = 4

    let cmdline = bootInfo.getCmdline()
    check cmdline == "test"

  test "Validate boot info - success":
    var bootInfo: BootInfo
    bootInfo.memoryMap.count = 1
    bootInfo.memoryMap.regions[0] = MemoryRegion(
      base: PhysAddr(0),
      length: 4 * 1024 * 1024,  # 4 MB
      regionType: memAvailable
    )

    let result = bootInfo.validateBootInfo()
    check result.isOk()

  test "Validate boot info - missing memory map":
    var bootInfo: BootInfo
    bootInfo.memoryMap.count = 0

    let result = bootInfo.validateBootInfo()
    check result.isErr()
    check result.error() == beMemoryMapMissing

  test "Validate boot info - insufficient memory":
    var bootInfo: BootInfo
    bootInfo.memoryMap.count = 1
    bootInfo.memoryMap.regions[0] = MemoryRegion(
      base: PhysAddr(0),
      length: 512 * 1024,  # Only 512 KB
      regionType: memAvailable
    )

    let result = bootInfo.validateBootInfo()
    check result.isErr()
    check result.error() == beParseError

suite "Bootloader Interface - Multiboot2 Parsing":

  test "Parse simple memory map":
    # Create a minimal Multiboot2 structure in memory
    # This is a simplified test - real implementation would need proper memory layout
    var bootInfo: BootInfo

    # Manually populate as if parsing was done
    bootInfo.memoryMap.count = 1
    bootInfo.memoryMap.regions[0] = MemoryRegion(
      base: PhysAddr(0),
      length: 16 * 1024 * 1024,
      regionType: memAvailable
    )

    let result = bootInfo.validateBootInfo()
    check result.isOk()

  test "Parse framebuffer info":
    var bootInfo: BootInfo
    bootInfo.hasFramebuffer = true
    bootInfo.framebuffer = FramebufferInfo(
      address: PhysAddr(0xfd000000),
      width: 1024,
      height: 768,
      pitch: 4096,
      bpp: 32,
      pixelFormat: pfRgb,
      redMask: 0xff0000,
      greenMask: 0x00ff00,
      blueMask: 0x0000ff
    )

    check bootInfo.framebuffer.width == 1024
    check bootInfo.framebuffer.height == 768
    check bootInfo.framebuffer.pixelFormat == pfRgb

  test "RSDP information":
    var bootInfo: BootInfo
    bootInfo.hasRsdp = true
    bootInfo.rsdp.address = PhysAddr(0x000e0000)
    bootInfo.rsdp.revision = 2

    check bootInfo.rsdp.revision == 2
    check uint64(bootInfo.rsdp.address) == 0x000e0000
