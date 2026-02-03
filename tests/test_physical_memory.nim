# SPDX-License-Identifier: GPL-2.0
## Tests for Physical Memory Manager Component

import unittest
import ../mm/physical_manager
import ../arch/common/boot_info
import ../core/types

suite "Physical Memory Manager - Component Tests":

  setup:
    # Create a mock boot info with typical memory layout
    var bootInfo: BootInfo
    bootInfo.memoryMap.count = 3

    # 0 - 1MB: Reserved
    bootInfo.memoryMap.regions[0] = MemoryRegion(
      base: PhysAddr(0),
      length: 1024 * 1024,
      regionType: memReserved
    )

    # 1MB - 16MB: DMA zone (available)
    bootInfo.memoryMap.regions[1] = MemoryRegion(
      base: PhysAddr(1024 * 1024),
      length: 15 * 1024 * 1024,
      regionType: memAvailable
    )

    # 16MB - 512MB: Normal zone (available)
    bootInfo.memoryMap.regions[2] = MemoryRegion(
      base: PhysAddr(16 * 1024 * 1024),
      length: 496 * 1024 * 1024,
      regionType: memAvailable
    )

  test "Zone configuration":
    # DMA zone should be 0-16MB
    check uint64(DmaLimit) == 16 * MiB

    # DMA32 zone should be 16MB-4GB
    check uint64(Dma32Limit) == 4 * GiB

  test "Get zone for frame":
    # Frame in DMA region
    let dmaBitFrame = uint64(8 * MiB) div FrameSize
    check getZoneForFrame(dmaBitFrame) == zoneDma

    # Frame in Normal region
    let normalFrame = uint64(64 * MiB) div FrameSize
    check getZoneForFrame(normalFrame) == zoneNormal

  test "Bitmap index calculation":
    let (word0, bit0) = frameToIndex(0)
    check word0 == 0
    check bit0 == 0

    let (word64, bit64) = frameToIndex(64)
    check word64 == 1
    check bit64 == 0

    let (wordMixed, bitMixed) = frameToIndex(65)
    check wordMixed == 1
    check bitMixed == 1

  test "Find first free bit":
    # All bits set (all used)
    let noFree = findFirstFreeInWord(high(uint64))
    check noFree == -1

    # First bit free
    let firstFree = findFirstFreeInWord(0xFFFFFFFFFFFFFFFE'u64)
    check firstFree == 0

    # Last bit free
    let lastFree = findFirstFreeInWord(0x7FFFFFFFFFFFFFFF'u64)
    check lastFree == 63

    # Second bit free
    let secondFree = findFirstFreeInWord(0xFFFFFFFFFFFFFFFD'u64)
    check secondFree == 1

  test "Validate frame address":
    var pmm = new PhysicalMemManager
    # Setup minimal manager
    pmm.totalFrames = 1000

    # Valid frame
    let validResult = pmm.validateFrame(PhysAddr(0))
    check validResult.isOk()

    # Valid frame with offset
    let validFrameResult = pmm.validateFrame(PhysAddr(4096))  # Frame size = 4096
    check validFrameResult.isOk()

    # Invalid: out of range
    let outOfRangeResult = pmm.validateFrame(PhysAddr(5000 * 4096))
    check outOfRangeResult.isErr()
    check outOfRangeResult.error() == feInvalidFrame

    # Invalid: not aligned
    let misalignedResult = pmm.validateFrame(PhysAddr(100))
    check misalignedResult.isErr()
    check misalignedResult.error() == feInvalidFrame

  test "Is frame in zone":
    var pmm = new PhysicalMemManager
    pmm.zones[zoneDma].startFrame = 0
    pmm.zones[zoneDma].endFrame = 4096  # 0-16MB

    pmm.zones[zoneNormal].startFrame = 4096
    pmm.zones[zoneNormal].endFrame = 1000000

    # Frame in DMA
    let dmaFrame = PhysAddr(1024)  # ~4MB
    check pmm.isFrameInZone(dmaFrame, zoneDma) == true
    check pmm.isFrameInZone(dmaFrame, zoneNormal) == false

    # Frame in Normal
    let normalFrame = PhysAddr(500000 * 4096)  # ~2GB
    check pmm.isFrameInZone(normalFrame, zoneNormal) == true
    check pmm.isFrameInZone(normalFrame, zoneDma) == false

  test "Zone info access":
    var pmm = new PhysicalMemManager
    pmm.zones[zoneDma].startFrame = 0
    pmm.zones[zoneDma].endFrame = 4096
    pmm.zones[zoneDma].totalFrames = 4096
    pmm.zones[zoneDma].freeFrames = 2048

    let zinfo = pmm.zoneInfo(zoneDma)
    check zinfo.totalFrames == 4096
    check zinfo.freeFrames == 2048
    check zinfo.startFrame == 0
    check zinfo.endFrame == 4096

  test "Zone fragmentation calculation":
    var pmm = new PhysicalMemManager

    # No free frames = no fragmentation
    pmm.zones[zoneDma].freeFrames = 0
    pmm.zones[zoneDma].totalFrames = 4096
    check pmm.zoneFragmentation(zoneDma) == 0.0

    # Some free frames
    pmm.zones[zoneDma].freeFrames = 2048
    let frag = pmm.zoneFragmentation(zoneDma)
    check frag >= 0.0
    check frag <= 1.0

suite "Physical Memory Manager - Frame Operations":

  test "Mark frame used and free":
    var pmm = new PhysicalMemManager
    pmm.bitmapSize = 2
    pmm.bitmap = cast[ptr UncheckedArray[uint64]](alloc(sizeof(uint64) * 2))
    pmm.bitmap[0] = 0
    pmm.bitmap[1] = 0

    # Mark frame 10 as used
    pmm.markFrameUsed(10)
    check pmm.isFrameUsed(10) == true
    check pmm.isFrameUsed(11) == false

    # Mark frame 10 as free
    pmm.markFrameFree(10)
    check pmm.isFrameUsed(10) == false

    dealloc(pmm.bitmap)

  test "Allocate and free single frame":
    var pmm = new PhysicalMemManager
    pmm.bitmapSize = 2
    pmm.bitmap = cast[ptr UncheckedArray[uint64]](alloc(sizeof(uint64) * 2))
    pmm.bitmap[0] = high(uint64)  # All used
    pmm.bitmap[1] = high(uint64)  # All used

    pmm.totalFrames = 128
    pmm.usedFrames = 128
    pmm.zones[zoneNormal].startFrame = 0
    pmm.zones[zoneNormal].endFrame = 128
    pmm.zones[zoneNormal].totalFrames = 128
    pmm.zones[zoneNormal].freeFrames = 0
    pmm.lock.init()

    # Mark frame 50 as free
    pmm.markFrameFree(50)
    pmm.usedFrames = 127
    pmm.zones[zoneNormal].freeFrames = 1

    # Allocate it back
    let result = pmm.allocFrame(zoneNormal)
    check result.isOk()
    check pmm.isFrameUsed(50) == true

    dealloc(pmm.bitmap)

  test "Allocate contiguous frames":
    var pmm = new PhysicalMemManager
    pmm.bitmapSize = 4
    pmm.bitmap = cast[ptr UncheckedArray[uint64]](alloc(sizeof(uint64) * 4))
    for i in 0..<4:
      pmm.bitmap[i] = high(uint64)  # All used initially

    pmm.totalFrames = 256
    pmm.usedFrames = 256
    pmm.zones[zoneNormal].startFrame = 0
    pmm.zones[zoneNormal].endFrame = 256
    pmm.zones[zoneNormal].totalFrames = 256
    pmm.zones[zoneNormal].freeFrames = 4
    pmm.lock.init()

    # Mark frames 100-103 as free
    for i in 100..<104:
      pmm.markFrameFree(uint64(i))
    pmm.usedFrames = 252

    # Allocate 4 contiguous frames
    let result = pmm.allocContiguous(4, zoneNormal)
    check result.isOk()
    let addr = uint64(result.get())
    check addr == 100 * FrameSize

    dealloc(pmm.bitmap)

  test "Double free detection":
    var pmm = new PhysicalMemManager
    pmm.bitmapSize = 1
    pmm.bitmap = cast[ptr UncheckedArray[uint64]](alloc(sizeof(uint64)))
    pmm.bitmap[0] = high(uint64)  # All used

    pmm.totalFrames = 64
    pmm.usedFrames = 64
    pmm.lock.init()

    # Try to free frame that's already free
    pmm.markFrameFree(10)
    let result = pmm.freeFrame(PhysAddr(10 * FrameSize))

    check result.isErr()
    check result.error() == feDoubleFree

    dealloc(pmm.bitmap)

suite "Physical Memory Manager - Statistics":

  test "Free frames calculation":
    var pmm = new PhysicalMemManager
    pmm.totalFrames = 1000
    pmm.usedFrames = 600

    let freeFrames = pmm.freeFrames()
    check freeFrames == 400

  test "Memory calculation":
    var pmm = new PhysicalMemManager
    pmm.totalFrames = 1000
    pmm.usedFrames = 600

    check pmm.totalMemory() == 1000 * FrameSize
    check pmm.usedMemory() == 600 * FrameSize
    check pmm.freeMemory() == 400 * FrameSize

  test "Statistics string generation":
    var pmm = new PhysicalMemManager
    pmm.totalFrames = 1000
    pmm.usedFrames = 600
    pmm.allocCount = 150
    pmm.freeCount = 50

    pmm.zones[zoneDma].totalFrames = 100
    pmm.zones[zoneDma].freeFrames = 30
    pmm.zones[zoneNormal].totalFrames = 900
    pmm.zones[zoneNormal].freeFrames = 370

    let stats = pmm.stats()
    check "Physical Memory Manager Stats" in stats
    check "Total Frames" in stats
    check "Free Frames" in stats
    check "Zone" in stats
