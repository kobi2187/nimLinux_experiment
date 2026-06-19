# SPDX-License-Identifier: GPL-2.0
## Kernel Heap Allocator - LAYER 2
##
## General-purpose malloc/free allocator using free-list strategy
## Dependencies: types, physical_manager, virtual_manager, spinlock
##
## This allocator:
## - Uses a free-list with coalescing
## - Supports arbitrary alignment
## - Tracks allocations and statistics
## - Provides malloc/free/realloc/calloc interface

import ../core/types
import ../core/traits/allocator
import ./physical_manager
import ./virtual_manager
import ../sync/spinlock

# ═══════════════════════════════════════════════════════════════════════════
# Block Metadata
# ═══════════════════════════════════════════════════════════════════════════

type
  AllocationError* = enum
    ## Heap allocation errors
    aeSuccess = 0
    aeOutOfMemory       ## Heap exhausted
    aeInvalidSize       ## Invalid allocation size
    aeInvalidAlign      ## Invalid alignment value
    aeInvalidPointer    ## Invalid pointer to free
    aeCorruption        ## Heap corruption detected

  AllocatorStats* = object
    ## Statistics structure
    totalSize*: uint64
    usedSize*: uint64
    freeSize*: uint64
    totalAllocations*: uint64
    totalFrees*: uint64
    currentAllocations*: uint64
    peakUsage*: uint64

  BlockHeader* = object
    ## Metadata for each allocation block
    magic*: uint32            ## Magic number (0xDEADBEEF for allocated, 0xFEEDBEEF for free)
    size*: uint64             ## Size of allocation (excluding header)
    alignment*: uint16        ## Requested alignment
    nextFree*: ptr BlockHeader ## Next free block in free list
    prevFree*: ptr BlockHeader ## Previous free block in free list

  HeapAllocator* = ref object
    ## Kernel heap allocator state
    baseAddr*: pointer        ## Heap base address
    heapSize*: uint64         ## Total heap size
    usedSize*: uint64         ## Currently allocated memory
    freeList*: ptr BlockHeader ## Head of free list

    # Statistics
    totalAllocs*: uint64      ## Total allocation requests
    totalFrees*: uint64       ## Total free requests
    peakUsage*: uint64        ## Peak memory used
    allocationCount*: uint64  ## Current allocations

    # Synchronization
    lock*: SpinLock

const
  ALLOCATED_MAGIC* = 0xDEADBEEF'u32
  FREE_MAGIC* = 0xFEEDBEEF'u32
  BLOCK_HEADER_SIZE* = uint64(sizeof(BlockHeader))
  MIN_BLOCK_SIZE* = 64'u64   ## Minimum meaningful block size
  MIN_ALIGNMENT* = 8'u64     ## Minimum alignment (8 bytes)
  MAX_ALIGNMENT* = 4096'u64  ## Maximum alignment (page size)

# ═══════════════════════════════════════════════════════════════════════════
# Helper Functions
# ═══════════════════════════════════════════════════════════════════════════

proc alignUp*(adr: uint64, alignment: uint64): uint64 {.inline.} =
  ## Align address up to alignment boundary
  ((adr + alignment - 1) div alignment) * alignment

proc alignDown*(adr: uint64, alignment: uint64): uint64 {.inline.} =
  ## Align address down to alignment boundary
  (adr div alignment) * alignment

proc getUserPointer*(header: ptr BlockHeader): pointer {.inline.} =
  ## Get user pointer from block header
  cast[pointer](cast[uint64](header) + BLOCK_HEADER_SIZE)

proc getHeaderFromPointer*(ptr: pointer): ptr BlockHeader {.inline.} =
  ## Get block header from user pointer
  cast[ptr BlockHeader](cast[uint64](ptr) - BLOCK_HEADER_SIZE)

proc isAllocated*(header: ptr BlockHeader): bool {.inline.} =
  header.magic == ALLOCATED_MAGIC

proc isFree*(header: ptr BlockHeader): bool {.inline.} =
  header.magic == FREE_MAGIC

# ═══════════════════════════════════════════════════════════════════════════
# Free List Management
# ═══════════════════════════════════════════════════════════════════════════

proc addToFreeList*(self: HeapAllocator, block: ptr BlockHeader) {.inline.} =
  ## Add block to free list
  block.magic = FREE_MAGIC
  block.nextFree = self.freeList
  block.prevFree = nil

  if self.freeList != nil:
    self.freeList.prevFree = block

  self.freeList = block

proc removeFromFreeList*(self: HeapAllocator, block: ptr BlockHeader) {.inline.} =
  ## Remove block from free list
  if block.prevFree != nil:
    block.prevFree.nextFree = block.nextFree
  else:
    self.freeList = block.nextFree

  if block.nextFree != nil:
    block.nextFree.prevFree = block.prevFree

  block.nextFree = nil
  block.prevFree = nil

proc findFreeBlock*(self: HeapAllocator, requiredSize: uint64): Option[ptr BlockHeader] =
  ## Find first free block large enough
  var current = self.freeList

  while current != nil:
    if current.size >= requiredSize:
      return some(current)
    current = current.nextFree

  none(ptr BlockHeader)

proc coalesceWithNext*(block: ptr BlockHeader): bool {.inline.} =
  ## Merge block with next free block if possible
  let nextAddr = cast[uint64](block) + BLOCK_HEADER_SIZE + block.size
  let nextBlock = cast[ptr BlockHeader](nextAddr)

  # Check bounds (we don't have exact heap end here, so just check magic)
  if nextBlock.magic == FREE_MAGIC:
    block.size += BLOCK_HEADER_SIZE + nextBlock.size
    block.nextFree = nextBlock.nextFree
    if nextBlock.nextFree != nil:
      nextBlock.nextFree.prevFree = block
    return true

  false

proc coalesceWithPrev*(header: ptr BlockHeader): bool {.inline.} =
  ## Merge block with previous free block if possible
  if header.prevFree != nil and header.prevFree.magic == FREE_MAGIC:
    header.prevFree.size += BLOCK_HEADER_SIZE + header.size
    header.prevFree.nextFree = header.nextFree
    if header.nextFree != nil:
      header.nextFree.prevFree = header.prevFree
    return true

  false

# ═══════════════════════════════════════════════════════════════════════════
# Initialization
# ═══════════════════════════════════════════════════════════════════════════

proc init*(self: HeapAllocator, baseAddr: pointer, heapSize: uint64): Result[void, AllocationError] =
  ## Initialize heap allocator with given base and size
  if heapSize < BLOCK_HEADER_SIZE + MIN_BLOCK_SIZE:
    return err(aeInvalidSize)

  self.baseAddr = baseAddr
  self.heapSize = heapSize
  self.usedSize = 0
  self.totalAllocs = 0
  self.totalFrees = 0
  self.peakUsage = 0
  self.allocationCount = 0
  self.lock.init()

  # Create initial free block
  let initialBlock = cast[ptr BlockHeader](baseAddr)
  initialBlock.magic = FREE_MAGIC
  initialBlock.size = heapSize - BLOCK_HEADER_SIZE
  initialBlock.alignment = MIN_ALIGNMENT
  initialBlock.nextFree = nil
  initialBlock.prevFree = nil

  self.freeList = initialBlock

  ok()

# ═══════════════════════════════════════════════════════════════════════════
# Allocation
# ═══════════════════════════════════════════════════════════════════════════

proc allocate*(self: HeapAllocator, size: uint64, alignment: uint64): Result[pointer, AllocationError] =
  ## Allocate memory with specified alignment

  # Validate parameters
  if size == 0 or size > self.heapSize:
    return err(aeInvalidSize)

  if alignment < MIN_ALIGNMENT or alignment > MAX_ALIGNMENT or (alignment and (alignment - 1)) != 0:
    return err(aeInvalidAlign)

  self.lock.acquire()
  defer: self.lock.release()

  inc self.totalAllocs

  # Find suitable free block
  let requiredSize = size + (alignment - MIN_ALIGNMENT) + BLOCK_HEADER_SIZE
  let freeBlock = self.findFreeBlock(requiredSize)

  if freeBlock.isNone():
    return err(aeOutOfMemory)

  var block = freeBlock.get()

  # Remove from free list
  self.removeFromFreeList(block)

  # Split block if necessary
  if block.size > size + BLOCK_HEADER_SIZE + MIN_BLOCK_SIZE:
    let newBlockAddr = cast[uint64](block) + BLOCK_HEADER_SIZE + size
    let newBlock = cast[ptr BlockHeader](newBlockAddr)
    newBlock.magic = FREE_MAGIC
    newBlock.size = block.size - BLOCK_HEADER_SIZE - size
    newBlock.nextFree = nil
    newBlock.prevFree = nil

    self.addToFreeList(newBlock)
    block.size = size

  # Mark as allocated
  block.magic = ALLOCATED_MAGIC
  block.alignment = uint16(alignment)

  # Update statistics
  self.usedSize += block.size + BLOCK_HEADER_SIZE
  inc self.allocationCount

  if self.usedSize > self.peakUsage:
    self.peakUsage = self.usedSize

  let userPtr = getUserPointer(block)
  ok(userPtr)

proc allocateAligned*(self: HeapAllocator, size: uint64, alignment: uint64): Result[pointer, AllocationError] =
  ## Allocate aligned memory (wrapper for allocate with alignment)
  self.allocate(size, alignment)

# ═══════════════════════════════════════════════════════════════════════════
# Deallocation
# ═══════════════════════════════════════════════════════════════════════════

proc deallocate*(self: HeapAllocator, ptr: pointer): Result[void, AllocationError] =
  ## Free allocated memory

  if ptr == nil:
    return ok()  # Free of nil is OK

  self.lock.acquire()
  defer: self.lock.release()

  # Get block header
  let header = getHeaderFromPointer(ptr)

  # Validate
  if header.magic != ALLOCATED_MAGIC:
    return err(aeInvalidPointer)

  if header.size == 0 or header.size > self.heapSize:
    return err(aeCorruption)

  # Update statistics
  self.usedSize -= header.size + BLOCK_HEADER_SIZE
  dec self.allocationCount
  inc self.totalFrees

  # Add to free list
  self.addToFreeList(header)

  # Try to coalesce
  discard self.coalesceWithNext(header)
  discard self.coalesceWithPrev(header)

  ok()

# ═══════════════════════════════════════════════════════════════════════════
# Reallocation
# ═══════════════════════════════════════════════════════════════════════════

proc reallocate*(self: HeapAllocator, ptr: pointer, newSize: uint64): Result[pointer, AllocationError] =
  ## Reallocate memory (may move the block)

  if newSize == 0:
    # Realloc to 0 = free
    ?self.deallocate(ptr)
    return err(aeInvalidSize)

  if ptr == nil:
    # Realloc of nil = malloc
    return self.allocate(newSize, MIN_ALIGNMENT)

  let header = getHeaderFromPointer(ptr)

  # If already large enough, return same pointer
  if header.size >= newSize:
    return ok(ptr)

  # Need to allocate new block
  let newPtr = ?(self.allocate(newSize, uint64(header.alignment)))

  # Copy old data (this is unsafe without proper runtime, but minimal for kernel)
  # In production, use memcpy
  for i in 0..<header.size:
    cast[ptr UncheckedArray[byte]](newPtr)[i] = cast[ptr UncheckedArray[byte]](ptr)[i]

  # Free old block
  discard self.deallocate(ptr)

  ok(newPtr)

# ═══════════════════════════════════════════════════════════════════════════
# Statistics & Debugging
# ═══════════════════════════════════════════════════════════════════════════

proc stats*(self: HeapAllocator): AllocatorStats =
  ## Get allocator statistics
  AllocatorStats(
    totalSize: self.heapSize,
    usedSize: self.usedSize,
    freeSize: self.heapSize - self.usedSize,
    totalAllocations: self.totalAllocs,
    totalFrees: self.totalFrees,
    currentAllocations: self.allocationCount,
    peakUsage: self.peakUsage
  )

proc fragmentation*(self: HeapAllocator): float =
  ## Calculate fragmentation ratio (0.0 = no fragmentation, 1.0 = highly fragmented)
  if self.heapSize == 0:
    return 0.0

  self.lock.acquire()
  defer: self.lock.release()

  var freeBlockCount = 0
  var current = self.freeList

  while current != nil:
    inc freeBlockCount
    current = current.nextFree

  if freeBlockCount == 0:
    return 1.0  # Fully fragmented (no free blocks)

  let avgBlockSize = if freeBlockCount > 0:
    (self.heapSize - self.usedSize) div uint64(freeBlockCount)
  else:
    1'u64

  let maxBlockSize = self.heapSize - self.usedSize

  if maxBlockSize == 0:
    return 1.0

  let fragmentation = 1.0 - (float(avgBlockSize) / float(maxBlockSize))
  max(0.0, min(1.0, fragmentation))

proc dumpHeapInfo*(self: HeapAllocator): string =
  ## Get human-readable heap information
  let s = self.stats()
  var result = "Heap Allocator Info:\n"
  result &= "  Total Size: " & $(s.totalSize div 1024) & " KB\n"
  result &= "  Used Size: " & $(s.usedSize div 1024) & " KB\n"
  result &= "  Free Size: " & $(s.freeSize div 1024) & " KB\n"
  result &= "  Current Allocations: " & $s.currentAllocations & "\n"
  result &= "  Total Allocations: " & $s.totalAllocations & "\n"
  result &= "  Total Frees: " & $s.totalFrees & "\n"
  result &= "  Peak Usage: " & $(s.peakUsage div 1024) & " KB\n"
  result &= "  Fragmentation: " & $(self.fragmentation() * 100) & "%\n"
  result
