# SPDX-License-Identifier: GPL-2.0
## Heap Manager - LAYER 2
##
## General purpose kernel memory allocator.
## Dependencies: types, physical_manager, virtual_manager, spinlock

import ../core/types
import ./physical_manager
import ./virtual_manager
import ../sync/spinlock
import ../core/serial

type
  # ═══════════════════════════════════════════════════════════════════════════
  # Error Types
  # ═══════════════════════════════════════════════════════════════════════════

  HeapError* = enum
    ## Heap allocation errors
    heNone = 0
    heOutOfMemory       ## No memory available
    heInvalidSize       ## Invalid allocation size
    heInvalidPointer    ## Invalid pointer to free
    heCorruption        ## Heap corruption detected
    heDoubleFree        ## Already freed

  # ═══════════════════════════════════════════════════════════════════════════
  # Free Block Header
  # ═══════════════════════════════════════════════════════════════════════════

  FreeBlock* = object
    ## Header for free memory blocks
    size*: uint64           ## Block size including header
    next*: ptr FreeBlock    ## Next free block

  # Allocated block has size stored before user pointer
  # [size: uint64][user data...]

  # ═══════════════════════════════════════════════════════════════════════════
  # Heap Manager
  # ═══════════════════════════════════════════════════════════════════════════

  HeapManager* = ref object
    ## Heap manager state
    physMgr*: PhysicalMemManager    ## Physical memory dependency
    virtMgr*: VirtualMemManager     ## Virtual memory dependency

    # Heap boundaries
    heapStart*: VirtAddr            ## Heap start address
    heapEnd*: VirtAddr              ## Current heap end
    heapMax*: VirtAddr              ## Maximum heap address
    heapFrontier*: VirtAddr         ## Current frontier/bump address

    # Free list
    freeList*: ptr FreeBlock        ## Head of free list

    # Synchronization
    lock*: SpinLock

    # Statistics
    totalAllocated*: uint64         ## Total bytes allocated
    totalFreed*: uint64             ## Total bytes freed
    currentUsed*: uint64            ## Current bytes in use
    peakUsed*: uint64               ## Peak usage
    allocCount*: uint64             ## Number of allocations
    freeCount*: uint64              ## Number of frees

var globalHeapManager*: HeapManager = nil

const
  # Heap configuration
  MinBlockSize* = 32'u64            ## Minimum block size
  HeapGrowSize* = 4 * MiB           ## Heap growth increment
  HeaderSize* = sizeof(uint64).uint64  ## Size header size
  DefaultHeapStart* = VirtAddr(0xFFFF_8080_0000_0000'u64)  ## Default kernel heap
  DefaultHeapMax* = VirtAddr(0xFFFF_80C0_0000_0000'u64)    ## Max 1TB heap

# ═══════════════════════════════════════════════════════════════════════════
# Initialization
# ═══════════════════════════════════════════════════════════════════════════

proc newHeapManager*(physMgr: PhysicalMemManager,
                     virtMgr: VirtualMemManager,
                     heapStart: VirtAddr = DefaultHeapStart,
                     heapMax: VirtAddr = DefaultHeapMax): HeapManager =
  ## Create a new heap manager
  result = HeapManager(
    physMgr: physMgr,
    virtMgr: virtMgr,
    heapStart: heapStart,
    heapEnd: heapStart,
    heapMax: heapMax,
    heapFrontier: heapStart,
    freeList: nil,
    totalAllocated: 0,
    totalFreed: 0,
    currentUsed: 0,
    peakUsed: 0,
    allocCount: 0,
    freeCount: 0
  )
  result.lock.init()
  globalHeapManager = result

# ═══════════════════════════════════════════════════════════════════════════
# Heap Growth
# ═══════════════════════════════════════════════════════════════════════════

proc grow(self: HeapManager, minSize: uint64): Result[void, HeapError] =
  ## Grow the heap by at least minSize bytes
  let growBy = max(HeapGrowSize, alignUp(minSize, FrameSize))
  let pages = growBy div FrameSize
  kprintln("    [HEAP] grow: growBy=" & $growBy & " pages=" & $pages)

  # Check if we'd exceed max
  if self.heapEnd + growBy > self.heapMax:
    kprintln("    [HEAP] grow: would exceed max")
    return err(heOutOfMemory)

  # Allocate and map pages
  for i in 0..<int(pages):
    let frame = self.physMgr.allocFrame()
    if frame.isErr:
      kprintln("    [HEAP] grow: allocFrame failed at i=" & $i)
      return err(heOutOfMemory)

    let mapResult = self.virtMgr.kernelMap(
      self.heapEnd + uint64(i) * FrameSize,
      frame.value,
      FrameSize,
      {pfPresent, pfWritable}
    )
    if mapResult.isErr:
      kprintln("    [HEAP] grow: kernelMap failed at i=" & $i)
      discard self.physMgr.freeFrame(frame.value)
      return err(heOutOfMemory)

  self.heapEnd = self.heapEnd + growBy
  ok()

# ═══════════════════════════════════════════════════════════════════════════
# Free List Management
# ═══════════════════════════════════════════════════════════════════════════

proc findFreeBlock(self: HeapManager, size: uint64): tuple[prev: ptr FreeBlock, curr: ptr FreeBlock] =
  ## Find a free block of at least size bytes
  ## Returns (previous, current) for list manipulation
  var prev: ptr FreeBlock = nil
  var curr = self.freeList

  while curr != nil:
    if curr.size >= size:
      return (prev, curr)
    prev = curr
    curr = curr.next

  return (nil, nil)

proc removeFromFreeList(self: HeapManager, prev: ptr FreeBlock, curr: ptr FreeBlock) =
  ## Remove block from free list
  if prev == nil:
    self.freeList = curr.next
  else:
    prev.next = curr.next

proc addToFreeList(self: HeapManager, blk: ptr FreeBlock) =
  ## Add block to free list (sorted by address for coalescing)
  let blkAddr = cast[uint64](blk)

  if self.freeList == nil or cast[uint64](self.freeList) > blkAddr:
    blk.next = self.freeList
    self.freeList = blk
    return

  var prev = self.freeList
  var curr = self.freeList.next

  while curr != nil and cast[uint64](curr) < blkAddr:
    prev = curr
    curr = curr.next

  blk.next = curr
  prev.next = blk

proc coalesce(self: HeapManager) =
  ## Merge adjacent free blocks
  var curr = self.freeList
  while curr != nil and curr.next != nil:
    let currEnd = cast[uint64](curr) + curr.size
    let nextStart = cast[uint64](curr.next)

    if currEnd == nextStart:
      # Merge with next block
      curr.size += curr.next.size
      curr.next = curr.next.next
    else:
      curr = curr.next

# ═══════════════════════════════════════════════════════════════════════════
# Allocation
# ═══════════════════════════════════════════════════════════════════════════

proc alloc*(self: HeapManager, size: uint64): Result[pointer, HeapError] =
  ## Allocate memory from heap
  if size == 0:
    return err(heInvalidSize)

  var guard = self.lock.acquireIrqSave()
  defer: guard.release()

  # Calculate actual size needed (header + data, aligned)
  let actualSize = alignUp(size + HeaderSize, MinBlockSize)

  kprintln("    [HEAP] alloc: actualSize=" & $actualSize)

  # Try free list first
  let (prev, curr) = self.findFreeBlock(actualSize)
  if curr != nil:
    kprintln("    [HEAP] alloc: found free block")
    self.removeFromFreeList(prev, curr)

    # Split block if significantly larger
    if curr.size >= actualSize + MinBlockSize + HeaderSize:
      let newBlock = cast[ptr FreeBlock](cast[uint64](curr) + actualSize)
      newBlock.size = curr.size - actualSize
      newBlock.next = nil
      self.addToFreeList(newBlock)
      curr.size = actualSize

    # Convert to allocated block
    let allocBlock = cast[ptr uint64](curr)
    allocBlock[] = curr.size  # Store size

    self.currentUsed += curr.size
    if self.currentUsed > self.peakUsed:
      self.peakUsed = self.currentUsed
    self.totalAllocated += curr.size
    inc self.allocCount

    return ok(cast[pointer](cast[uint64](allocBlock) + HeaderSize))

  kprintln("    [HEAP] alloc: no free block, growing heap...")

  let currentTop = self.heapFrontier
  if currentTop + actualSize > self.heapEnd:
    let growResult = self.grow(actualSize)
    if growResult.isErr:
      kprintln("    [HEAP] alloc: grow failed")
      return err(heOutOfMemory)

  # Allocate at current top
  let allocBlock = cast[ptr uint64](currentTop)
  allocBlock[] = actualSize
  self.heapFrontier = currentTop + actualSize

  self.currentUsed += actualSize
  if self.currentUsed > self.peakUsed:
    self.peakUsed = self.currentUsed
  self.totalAllocated += actualSize
  inc self.allocCount

  ok(cast[pointer](cast[uint64](allocBlock) + HeaderSize))

proc free*(self: HeapManager, p: pointer): Result[void, HeapError] =
  ## Free allocated memory
  if p == nil:
    return ok()

  var guard = self.lock.acquireIrqSave()
  defer: guard.release()

  # Get block header
  let blockAddr = cast[uint64](p) - HeaderSize
  let sizePtr = cast[ptr uint64](blockAddr)

  # Validate pointer is in heap
  if blockAddr < uint64(self.heapStart) or blockAddr >= uint64(self.heapEnd):
    return err(heInvalidPointer)

  let blockSize = sizePtr[]

  # Convert to free block and add to list
  let freeBlk = cast[ptr FreeBlock](blockAddr)
  freeBlk.size = blockSize
  freeBlk.next = nil

  self.addToFreeList(freeBlk)
  self.coalesce()

  self.currentUsed -= blockSize
  self.totalFreed += blockSize
  inc self.freeCount

  ok()

proc allocAligned*(self: HeapManager, size: uint64, align: uint64): Result[pointer, HeapError] =
  ## Allocate aligned memory
  if align <= MinBlockSize:
    return self.alloc(size)

  # Over-allocate to ensure we can align
  let totalSize = size + align
  let rawPtr = ?self.alloc(totalSize)

  # Align within the allocation
  let aligned = alignUp(cast[uint64](rawPtr), align)

  # Note: This wastes memory before alignment point
  # A more sophisticated allocator would handle this better
  ok(cast[pointer](aligned))

proc realloc*(self: HeapManager, p: pointer, newSize: uint64): Result[pointer, HeapError] =
  ## Reallocate memory
  if p == nil:
    return self.alloc(newSize)

  if newSize == 0:
    discard self.free(p)
    return ok(nil)

  # Get old size
  let oldSizePtr = cast[ptr uint64](cast[uint64](p) - HeaderSize)
  let oldSize = oldSizePtr[] - HeaderSize

  if newSize <= oldSize:
    return ok(p)

  # Allocate new, copy, free old
  let newPtr = ?self.alloc(newSize)

  # Copy data
  let copySize = min(oldSize, newSize)
  let src = cast[ptr UncheckedArray[uint8]](p)
  let dst = cast[ptr UncheckedArray[uint8]](newPtr)
  for i in 0..<int(copySize):
    dst[i] = src[i]

  discard self.free(p)
  ok(newPtr)

# ═══════════════════════════════════════════════════════════════════════════
# Information
# ═══════════════════════════════════════════════════════════════════════════

proc stats*(self: HeapManager): tuple[allocated, freed, current, peak: uint64] =
  (self.totalAllocated, self.totalFreed, self.currentUsed, self.peakUsed)

proc freeMemory*(self: HeapManager): uint64 =
  ## Get total free memory in heap
  var guard = self.lock.acquireIrqSave()
  defer: guard.release()

  result = 0
  var blk = self.freeList
  while blk != nil:
    result += blk.size
    blk = blk.next

  # Add unmapped space
  result += uint64(self.heapMax) - uint64(self.heapEnd)

# ═══════════════════════════════════════════════════════════════════════════
# Global Allocator Interface & Shims for C / Nim Runtime
# ═══════════════════════════════════════════════════════════════════════════

const
  MagicEarly = 0xEAEAEA01'u64
  MagicLate  = 0xEAEAEA02'u64
  EarlyArenaSize = 1024 * 1024 # 1 MB for early boot/startup allocations

type
  MallocHeader = object
    magic: uint64
    size: uint64

var earlyArena {.align: 16.}: array[EarlyArenaSize, byte]
var earlyAllocated = 0

proc earlyAlloc(size: uint64): pointer =
  let aligned = alignUp(size, 16)
  if earlyAllocated + int(aligned) > EarlyArenaSize:
    return nil
  let p = addr earlyArena[earlyAllocated]
  earlyAllocated += int(aligned)
  p

proc malloc*(size: csize_t): pointer {.exportc: "malloc", cdecl.} =
  kprintln("  [HEAP] malloc: size=" & $uint64(size))
  let totalSize = uint64(size) + uint64(sizeof(MallocHeader))
  var rawPtr: pointer = nil
  var magic: uint64
  
  if globalHeapManager != nil:
    let res = globalHeapManager.alloc(totalSize)
    if res.isOk:
      rawPtr = res.value
      magic = MagicLate
  else:
    rawPtr = earlyAlloc(totalSize)
    magic = MagicEarly
    
  if rawPtr == nil:
    return nil
    
  let header = cast[ptr MallocHeader](rawPtr)
  header.magic = magic
  header.size = uint64(size)
  
  let userPtr = cast[pointer](cast[uint64](rawPtr) + uint64(sizeof(MallocHeader)))
  kprintln("  [HEAP] malloc: returned userPtr=" & $cast[uint64](userPtr))
  userPtr

proc free*(p: pointer) {.exportc: "free", cdecl.} =
  if p == nil: return
  let headerAddr = cast[uint64](p) - uint64(sizeof(MallocHeader))
  let header = cast[ptr MallocHeader](headerAddr)
  
  kprintln("  [HEAP] free: p=" & $cast[uint64](p) & " magic=" & $header.magic)
  if header.magic == MagicLate:
    if globalHeapManager != nil:
      discard globalHeapManager.free(cast[pointer](headerAddr))
  # Early allocator frees are no-ops

proc realloc*(p: pointer, size: csize_t): pointer {.exportc: "realloc", cdecl.} =
  if p == nil:
    return malloc(size)
  if size == 0:
    free(p)
    return nil
    
  let headerAddr = cast[uint64](p) - uint64(sizeof(MallocHeader))
  let header = cast[ptr MallocHeader](headerAddr)
  let oldSize = header.size
  
  # Allocate new block
  let newPtr = malloc(size)
  if newPtr == nil:
    return nil
    
  # Copy data
  let copySize = min(oldSize, uint64(size))
  kprintln("  [HEAP] realloc: p=" & $cast[uint64](p) & " oldSize=" & $oldSize & " newSize=" & $size & " newPtr=" & $cast[uint64](newPtr) & " copySize=" & $copySize)
  copyMem(newPtr, p, int(copySize))
  
  # Free old block
  free(p)
  newPtr

proc calloc*(nmemb, size: csize_t): pointer {.exportc: "calloc", cdecl.} =
  let total = uint64(nmemb) * uint64(size)
  let p = malloc(csize_t(total))
  if p != nil:
    zeroMem(p, int(total))
  p
