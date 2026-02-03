# SPDX-License-Identifier: GPL-2.0
## Tests for Heap Allocator Component

import unittest
import ../mm/heap_allocator
import ../core/types

suite "Heap Allocator - Component Tests":

  test "Alignment calculations":
    check alignUp(0, 8) == 0
    check alignUp(1, 8) == 8
    check alignUp(8, 8) == 8
    check alignUp(9, 8) == 16
    check alignUp(100, 16) == 112
    check alignUp(4095, 4096) == 4096
    check alignUp(4097, 4096) == 8192

  test "Alignment down calculations":
    check alignDown(0, 8) == 0
    check alignDown(1, 8) == 0
    check alignDown(7, 8) == 0
    check alignDown(8, 8) == 8
    check alignDown(15, 8) == 8
    check alignDown(100, 16) == 96

  test "Block header to user pointer conversion":
    var header: BlockHeader
    header.magic = ALLOCATED_MAGIC
    let headerPtr = addr header
    let userPtr = getUserPointer(headerPtr)

    check cast[uint64](userPtr) == cast[uint64](headerPtr) + BLOCK_HEADER_SIZE

  test "User pointer to block header recovery":
    var header: BlockHeader
    header.magic = ALLOCATED_MAGIC
    let headerPtr = addr header
    let userPtr = getUserPointer(headerPtr)
    let recoveredHeader = getHeaderFromPointer(userPtr)

    check recoveredHeader.magic == ALLOCATED_MAGIC
    check recoveredHeader == headerPtr

  test "Block state checking":
    var allocBlock: BlockHeader
    allocBlock.magic = ALLOCATED_MAGIC
    check allocBlock.isAllocated() == true
    check allocBlock.isFree() == false

    var freeBlock: BlockHeader
    freeBlock.magic = FREE_MAGIC
    check freeBlock.isAllocated() == false
    check freeBlock.isFree() == true

  test "Magic numbers are distinct":
    check ALLOCATED_MAGIC != FREE_MAGIC

  test "Block header size is reasonable":
    check BLOCK_HEADER_SIZE > 0
    check BLOCK_HEADER_SIZE < 256  # Shouldn't be huge

  test "Alignment constants are valid":
    check MIN_ALIGNMENT == 8
    check MAX_ALIGNMENT == 4096
    check MIN_ALIGNMENT < MAX_ALIGNMENT
    check (MAX_ALIGNMENT and (MAX_ALIGNMENT - 1)) == 0  # Power of 2

  test "Minimum block size makes sense":
    check MIN_BLOCK_SIZE >= BLOCK_HEADER_SIZE

suite "Heap Allocator - Initialization":

  test "Initialize heap allocator":
    var buffer: array[4096, byte]
    var allocator = new HeapAllocator

    let result = allocator.init(addr buffer[0], 4096)
    check result.isOk()

    let stats = allocator.stats()
    check stats.totalSize == 4096
    check stats.usedSize == 0
    check stats.freeSize == 4096
    check stats.currentAllocations == 0

  test "Initialize with too small heap":
    var buffer: array[16, byte]
    var allocator = new HeapAllocator

    let result = allocator.init(addr buffer[0], 16)
    check result.isErr()
    check result.error() == aeInvalidSize

  test "Initial free list setup":
    var buffer: array[8192, byte]
    var allocator = new HeapAllocator

    discard allocator.init(addr buffer[0], 8192)
    check allocator.freeList != nil
    check allocator.freeList.isFree() == true

suite "Heap Allocator - Allocation":

  test "Allocate single block":
    var buffer: array[4096, byte]
    var allocator = new HeapAllocator
    discard allocator.init(addr buffer[0], 4096)

    let result = allocator.allocate(256, 8)
    check result.isOk()

    let ptr = result.value
    check ptr != nil
    check allocator.allocationCount == 1

  test "Allocate with default alignment":
    var buffer: array[4096, byte]
    var allocator = new HeapAllocator
    discard allocator.init(addr buffer[0], 4096)

    let result = allocator.allocate(128, MIN_ALIGNMENT)
    check result.isOk()
    check allocator.stats().currentAllocations == 1

  test "Allocate out of memory":
    var buffer: array[256, byte]
    var allocator = new HeapAllocator
    discard allocator.init(addr buffer[0], 256)

    # Try to allocate more than available
    let result = allocator.allocate(1024, MIN_ALIGNMENT)
    check result.isErr()
    check result.error() == aeOutOfMemory

  test "Allocate with invalid size":
    var buffer: array[4096, byte]
    var allocator = new HeapAllocator
    discard allocator.init(addr buffer[0], 4096)

    let result = allocator.allocate(0, MIN_ALIGNMENT)
    check result.isErr()
    check result.error() == aeInvalidSize

  test "Allocate with invalid alignment":
    var buffer: array[4096, byte]
    var allocator = new HeapAllocator
    discard allocator.init(addr buffer[0], 4096)

    # Invalid: not power of 2
    let result1 = allocator.allocate(256, 7)
    check result1.isErr()

    # Invalid: too small
    let result2 = allocator.allocate(256, 2)
    check result2.isErr()

    # Invalid: too large
    let result3 = allocator.allocate(256, 8192)
    check result3.isErr()

  test "Multiple allocations":
    var buffer: array[8192, byte]
    var allocator = new HeapAllocator
    discard allocator.init(addr buffer[0], 8192)

    let ptr1 = allocator.allocate(256, MIN_ALIGNMENT).value
    let ptr2 = allocator.allocate(256, MIN_ALIGNMENT).value
    let ptr3 = allocator.allocate(256, MIN_ALIGNMENT).value

    check allocator.allocationCount == 3
    check ptr1 != ptr2
    check ptr2 != ptr3

suite "Heap Allocator - Deallocation":

  test "Free allocated block":
    var buffer: array[4096, byte]
    var allocator = new HeapAllocator
    discard allocator.init(addr buffer[0], 4096)

    let ptr = allocator.allocate(256, MIN_ALIGNMENT).value
    let freeResult = allocator.deallocate(ptr)

    check freeResult.isOk()
    check allocator.allocationCount == 0

  test "Free nil is OK":
    var buffer: array[4096, byte]
    var allocator = new HeapAllocator
    discard allocator.init(addr buffer[0], 4096)

    let result = allocator.deallocate(nil)
    check result.isOk()

  test "Free invalid pointer":
    var buffer: array[4096, byte]
    var allocator = new HeapAllocator
    discard allocator.init(addr buffer[0], 4096)

    let result = allocator.deallocate(cast[pointer](0x12345678))
    check result.isErr()
    # Could be corruption or invalid pointer depending on content

  test "Allocate and free multiple":
    var buffer: array[8192, byte]
    var allocator = new HeapAllocator
    discard allocator.init(addr buffer[0], 8192)

    let ptrs: array[5, pointer] = [
      allocator.allocate(256, MIN_ALIGNMENT).value,
      allocator.allocate(256, MIN_ALIGNMENT).value,
      allocator.allocate(256, MIN_ALIGNMENT).value,
      allocator.allocate(256, MIN_ALIGNMENT).value,
      allocator.allocate(256, MIN_ALIGNMENT).value
    ]

    check allocator.allocationCount == 5

    # Free in reverse order
    for i in countdown(4, 0):
      discard allocator.deallocate(ptrs[i])

    check allocator.allocationCount == 0

suite "Heap Allocator - Statistics":

  test "Statistics after allocation":
    var buffer: array[4096, byte]
    var allocator = new HeapAllocator
    discard allocator.init(addr buffer[0], 4096)

    discard allocator.allocate(256, MIN_ALIGNMENT)
    let stats = allocator.stats()

    check stats.totalSize == 4096
    check stats.usedSize > 0
    check stats.freeSize < 4096
    check stats.currentAllocations == 1
    check stats.totalAllocations == 1

  test "Statistics track peak usage":
    var buffer: array[4096, byte]
    var allocator = new HeapAllocator
    discard allocator.init(addr buffer[0], 4096)

    discard allocator.allocate(1024, MIN_ALIGNMENT)
    let peakAfterFirst = allocator.stats().peakUsage

    discard allocator.allocate(512, MIN_ALIGNMENT)
    let peakAfterSecond = allocator.stats().peakUsage

    check peakAfterSecond >= peakAfterFirst

  test "Heap dump info":
    var buffer: array[4096, byte]
    var allocator = new HeapAllocator
    discard allocator.init(addr buffer[0], 4096)

    discard allocator.allocate(256, MIN_ALIGNMENT)
    let info = allocator.dumpHeapInfo()

    check "Heap Allocator Info" in info
    check "Total Size" in info
    check "Used Size" in info
    check "Current Allocations: 1" in info

  test "Fragmentation calculation":
    var buffer: array[8192, byte]
    var allocator = new HeapAllocator
    discard allocator.init(addr buffer[0], 8192)

    # Initially no fragmentation
    let initialFrag = allocator.fragmentation()
    check initialFrag >= 0.0
    check initialFrag <= 1.0

    # After allocation
    discard allocator.allocate(256, MIN_ALIGNMENT)
    let afterAllocFrag = allocator.fragmentation()
    check afterAllocFrag >= 0.0
    check afterAllocFrag <= 1.0

suite "Heap Allocator - Reallocation":

  test "Reallocate to larger size":
    var buffer: array[8192, byte]
    var allocator = new HeapAllocator
    discard allocator.init(addr buffer[0], 8192)

    let ptr1 = allocator.allocate(256, MIN_ALIGNMENT).value
    let ptr2 = allocator.reallocate(ptr1, 512)

    check ptr2.isOk()
    # Note: ptr may or may not be the same depending on coalescing

  test "Reallocate to zero is error":
    var buffer: array[4096, byte]
    var allocator = new HeapAllocator
    discard allocator.init(addr buffer[0], 4096)

    let ptr = allocator.allocate(256, MIN_ALIGNMENT).value
    let result = allocator.reallocate(ptr, 0)

    check result.isErr()

  test "Reallocate nil is allocate":
    var buffer: array[4096, byte]
    var allocator = new HeapAllocator
    discard allocator.init(addr buffer[0], 4096)

    let result = allocator.reallocate(nil, 256)
    check result.isOk()
    check allocator.allocationCount == 1
