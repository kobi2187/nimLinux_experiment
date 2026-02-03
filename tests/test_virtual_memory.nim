# SPDX-License-Identifier: GPL-2.0
## Tests for Virtual Memory Manager Component

import unittest
import ../mm/virtual_manager
import ../mm/physical_manager
import ../arch/common/boot_info
import ../core/types

suite "Virtual Memory Manager - Component Tests":

  test "Page flag conversions":
    var flags = {pfPresent, pfWritable, pfUser}
    let entry = flagsToEntry(flags)

    check (entry and PTE_PRESENT) != 0
    check (entry and PTE_WRITABLE) != 0
    check (entry and PTE_USER) != 0

    let reconverted = entryToFlags(entry)
    check pfPresent in reconverted
    check pfWritable in reconverted
    check pfUser in reconverted

  test "Virtual address index extraction":
    # Test address 0x123456789ABC
    let addr = VirtAddr(0x123456789ABC'u64)

    let pml4Idx = getVirtIndex(addr, 4)
    let pdptIdx = getVirtIndex(addr, 3)
    let pdIdx = getVirtIndex(addr, 2)
    let ptIdx = getVirtIndex(addr, 1)

    check pml4Idx >= 0 and pml4Idx < 512
    check pdptIdx >= 0 and pdptIdx < 512
    check pdIdx >= 0 and pdIdx < 512
    check ptIdx >= 0 and ptIdx < 512

  test "Canonical address validation":
    # Valid kernel address
    let kernelAddr = VirtAddr(0xFFFF800000000000'u64)
    check validateVirtAddr(kernelAddr) == true

    # Valid user address
    let userAddr = VirtAddr(0x0000123456789ABC'u64)
    check validateVirtAddr(userAddr) == true

    # Invalid canonical address (bits 48-62 mixed)
    let invalidAddr = VirtAddr(0x0000FFFFFFFFFFFF'u64)
    check validateVirtAddr(invalidAddr) == false

  test "Mapping validation":
    # Valid mapping
    let addr = VirtAddr(0x1000)
    let result = validateMapping(addr, 4096)
    check result.isOk()

    # Invalid: zero length
    let zeroLenResult = validateMapping(addr, 0)
    check zeroLenResult.isErr()

    # Invalid: unaligned length
    let unalignedResult = validateMapping(addr, 4095)
    check unalignedResult.isErr()

  test "Page flag sets":
    # Empty flags
    var emptyFlags: set[PageFlags] = {}
    check emptyFlags.len == 0

    # Multiple flags
    var multiFlags = {pfPresent, pfWritable, pfUser, pfGlobal}
    check pfPresent in multiFlags
    check pfGlobal in multiFlags
    check pfNoExecute notin multiFlags

  test "PTE bit masks":
    check PTE_PRESENT == 1
    check PTE_WRITABLE == 2
    check PTE_USER == 4
    check PTE_NX == (1'u64 shl 63)

  test "Virtual address bit shifts":
    check PML4_SHIFT == 39
    check PDPT_SHIFT == 30
    check PD_SHIFT == 21
    check PT_SHIFT == 12

  test "Page table entry size":
    check PT_ENTRIES == 512
    check PT_SIZE == 4096

  test "Address component extraction":
    # Address: 0x00007F1234567890
    let addr = uint64(0x00007F1234567890)

    let pml4Part = (addr shr PML4_SHIFT) and 0x1FF
    let pdptPart = (addr shr PDPT_SHIFT) and 0x1FF
    let pdPart = (addr shr PD_SHIFT) and 0x1FF
    let ptPart = (addr shr PT_SHIFT) and 0x1FF
    let pageOffsetPart = addr and 0xFFF

    check pml4Part >= 0 and pml4Part < 512
    check pdptPart >= 0 and pdptPart < 512
    check pdPart >= 0 and pdPart < 512
    check ptPart >= 0 and ptPart < 512
    check pageOffsetPart < 4096

suite "Virtual Memory Manager - Address Space Management":

  test "Virtual address space creation":
    var bootInfo: BootInfo
    bootInfo.memoryMap.count = 1
    bootInfo.memoryMap.regions[0] = MemoryRegion(
      base: PhysAddr(0),
      length: 256 * MiB,
      regionType: memAvailable
    )

    var physMgr = new PhysicalMemManager
    # Would need to initialize properly in real test

  test "Region information tracking":
    var space = new AddressSpace
    space.regions = @[]
    space.refCount = 1

    let virt = VirtAddr(0x1000)
    var flags = {pfPresent, pfWritable}

    space.addRegionInfo(virt, 4096, flags, "heap")

    check space.regions.len == 1
    check space.regions[0].start == virt
    check space.regions[0].length == 4096
    check pfPresent in space.regions[0].flags
    check pfWritable in space.regions[0].flags

  test "Multiple regions":
    var space = new AddressSpace
    space.regions = @[]
    space.refCount = 1

    space.addRegionInfo(VirtAddr(0x1000), 4096, {pfPresent}, "stack")
    space.addRegionInfo(VirtAddr(0x2000), 8192, {pfPresent, pfWritable}, "heap")
    space.addRegionInfo(VirtAddr(0x4000), 16384, {pfPresent, pfUser}, "data")

    check space.regions.len == 3
    check space.regions[0].name[0] == 's'  # "stack"
    check space.regions[1].name[0] == 'h'  # "heap"

suite "Virtual Memory Manager - Utilities":

  test "Address space info string":
    var space = new AddressSpace
    space.root = PhysAddr(0x12345000)
    space.refCount = 2
    space.regions = @[]

    let info = space.getAddressSpaceInfo()
    check "Address Space Information" in info
    check "Root (CR3)" in info
    check "Regions: 0" in info

  test "Address space info with regions":
    var space = new AddressSpace
    space.root = PhysAddr(0x12345000)
    space.refCount = 1
    space.regions = @[]

    space.addRegionInfo(VirtAddr(0x1000), 4096, {pfPresent}, "code")
    space.addRegionInfo(VirtAddr(0x2000), 8192, {pfPresent, pfWritable}, "data")

    let info = space.getAddressSpaceInfo()
    check "Regions: 2" in info
    check "0x1000" in info
    check "0x2000" in info

  test "Region metadata preservation":
    var space = new AddressSpace
    space.regions = @[]

    let regionName = "test_region"
    space.addRegionInfo(VirtAddr(0x5000), 8192, {pfPresent, pfWritable, pfUser}, regionName)

    check space.regions.len == 1
    let region = space.regions[0]
    check region.start == VirtAddr(0x5000)
    check region.length == 8192
    check pfPresent in region.flags
    check pfWritable in region.flags
    check pfUser in region.flags

  test "Flag combinations":
    let kernelFlags = {pfPresent, pfWritable, pfGlobal, pfNoExecute}
    let userFlags = {pfPresent, pfWritable, pfUser}
    let readOnlyFlags = {pfPresent}

    let kernelEntry = flagsToEntry(kernelFlags)
    let userEntry = flagsToEntry(userFlags)
    let readOnlyEntry = flagsToEntry(readOnlyFlags)

    check (kernelEntry and PTE_GLOBAL) != 0
    check (kernelEntry and PTE_NX) != 0
    check (userEntry and PTE_USER) != 0
    check (readOnlyEntry and PTE_WRITABLE) == 0

suite "Virtual Memory Manager - Constants":

  test "Zone boundary checks":
    let maxUserAddr = uint64(0x00007FFFFFFFFFFF)
    let minKernelAddr = uint64(0xFFFF800000000000)

    check minKernelAddr > maxUserAddr
    check (maxUserAddr and 0xFFFF000000000000) == 0
    check (minKernelAddr and 0xFFFF000000000000) == 0xFFFF000000000000
