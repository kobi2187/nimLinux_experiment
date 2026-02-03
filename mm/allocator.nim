# SPDX-License-Identifier: GPL-2.0
## Memory Allocator Interface
##
## Unified interface for different allocation strategies
## Supports malloc-style and slab allocation

import ../core/types

type
  # ═══════════════════════════════════════════════════════════════════════════
  # Allocator Types
  # ═══════════════════════════════════════════════════════════════════════════

  AllocatorType* = enum
    atFreeList = 0                 ## First-fit free list (general purpose)
    atBuddy = 1                    ## Buddy system (power-of-2 blocks)
    atSlab = 2                     ## Slab allocator (object caches)
    atBitmap = 3                   ## Bitmap allocator (fixed size blocks)

  AllocatorStats* = object
    ## Allocator statistics
    allocType*: AllocatorType
    totalMemory*: uint64
    usedMemory*: uint64
    freeMemory*: uint64
    allocationCount*: uint64
    freeCount*: uint64
    fragmentationPercent*: float

  AllocationInfo* = object
    ## Information about an allocation
    address*: pointer
    size*: uint64
    allocatorType*: AllocatorType
    allocatedAt*: uint64            ## Allocation time tick
    flags*: uint16

  AllocatorOps* = object
    ## Generic allocator operations
    allocate*: proc(size: uint64, alignment: uint64): pointer
    deallocate*: proc(ptr: pointer): bool
    reallocate*: proc(ptr: pointer, newSize: uint64): pointer
    getStats*: proc(): AllocatorStats
    defragment*: proc(): bool

# ═══════════════════════════════════════════════════════════════════════════
# Free List Allocator
# ═══════════════════════════════════════════════════════════════════════════

type
  FreeListNode* = object
    ## Node in free list
    size*: uint64
    nextFree*: ptr FreeListNode
    prevFree*: ptr FreeListNode
    isFree*: bool

proc freeListAllocate*(memStart: pointer, memSize: uint64, requestSize: uint64): pointer =
  ## Allocate using free list (first-fit)
  # Would traverse free list and find suitable block
  nil

proc freeListDeallocate*(ptr: pointer): bool =
  ## Free block using free list
  # Would return block to free list and coalesce adjacent free blocks
  false

# ═══════════════════════════════════════════════════════════════════════════
# Buddy System Allocator
# ═══════════════════════════════════════════════════════════════════════════

const
  BuddyMinOrder* = 5                 ## Minimum 2^5 = 32 byte blocks
  BuddyMaxOrder* = 20                ## Maximum 2^20 = 1 MB blocks

type
  BuddyAllocator* = object
    ## Buddy system allocator state
    freeBlocks*: array[BuddyMaxOrder - BuddyMinOrder + 1, uint32]
    totalBlocks*: array[BuddyMaxOrder - BuddyMinOrder + 1, uint32]

proc buddyAllocate*(allocator: var BuddyAllocator, size: uint64): pointer =
  ## Allocate using buddy system
  # Calculate order needed
  # Check free blocks at that order and larger
  # Split larger blocks if necessary
  nil

proc buddyDeallocate*(allocator: var BuddyAllocator, ptr: pointer, size: uint64): bool =
  ## Free block using buddy system
  # Mark block as free
  # Coalesce with buddy if also free
  # Recursively merge upwards
  false

# ═══════════════════════════════════════════════════════════════════════════
# Slab Allocator
# ═══════════════════════════════════════════════════════════════════════════

const
  MaxSlabCaches* = 64
  MaxSlabsPerCache* = 256

type
  SlabCache* = object
    ## Cache of same-sized objects
    objectSize*: uint64
    slabSize*: uint64
    objectsPerSlab*: uint32
    slabs*: array[MaxSlabsPerCache, pointer]
    slabCount*: uint32
    freeObjects*: uint32

proc slabCacheCreate*(objectSize: uint64, slabSize: uint64 = 4096): ptr SlabCache =
  ## Create slab cache for fixed-size objects
  # Would allocate and initialize cache
  nil

proc slabAllocate*(cache: ptr SlabCache): pointer =
  ## Allocate object from slab cache
  # Find slab with free object
  # Mark object as allocated
  # Return pointer
  nil

proc slabDeallocate*(cache: ptr SlabCache, ptr: pointer): bool =
  ## Free object back to slab cache
  # Mark object as free
  # Return true if successful
  false

proc slabCacheStats*(cache: ptr SlabCache): AllocatorStats =
  ## Get statistics for slab cache
  result.allocType = atSlab
  if cache != nil:
    result.freeMemory = uint64(cache.freeObjects) * cache.objectSize

# ═══════════════════════════════════════════════════════════════════════════
# Generic Allocator Interface
# ═══════════════════════════════════════════════════════════════════════════

var
  gCurrentAllocator*: AllocatorOps
  gAllocatorType*: AllocatorType = atFreeList

proc setAllocator*(ops: AllocatorOps, allocType: AllocatorType) =
  ## Set current memory allocator
  gCurrentAllocator = ops
  gAllocatorType = allocType

proc getAllocatorType*(): AllocatorType =
  ## Get current allocator type
  return gAllocatorType

proc allocate*(size: uint64, alignment: uint64 = 8): pointer =
  ## Generic allocate
  if gCurrentAllocator.allocate != nil:
    return gCurrentAllocator.allocate(size, alignment)
  return nil

proc deallocate*(ptr: pointer): bool =
  ## Generic deallocate
  if gCurrentAllocator.deallocate != nil:
    return gCurrentAllocator.deallocate(ptr)
  return false

proc reallocate*(ptr: pointer, newSize: uint64): pointer =
  ## Generic reallocate
  if gCurrentAllocator.reallocate != nil:
    return gCurrentAllocator.reallocate(ptr, newSize)
  return nil

# ═══════════════════════════════════════════════════════════════════════════
# Allocation Tracking
# ═══════════════════════════════════════════════════════════════════════════

const
  MaxTrackedAllocations* = 8192

var
  gAllocationTracker*: array[MaxTrackedAllocations, AllocationInfo]
  gTrackerCount*: uint32 = 0

proc trackAllocation*(ptr: pointer, size: uint64, allocType: AllocatorType) =
  ## Track allocation for debugging
  if gTrackerCount < MaxTrackedAllocations:
    gAllocationTracker[gTrackerCount].address = ptr
    gAllocationTracker[gTrackerCount].size = size
    gAllocationTracker[gTrackerCount].allocatorType = allocType
    inc gTrackerCount

proc untrackAllocation*(ptr: pointer): bool =
  ## Untrack allocation
  for i in 0..<gTrackerCount:
    if gAllocationTracker[i].address == ptr:
      # Remove by shifting
      for j in i..<gTrackerCount - 1:
        gAllocationTracker[j] = gAllocationTracker[j + 1]
      if gTrackerCount > 0:
        dec gTrackerCount
      return true
  return false

proc getAllocationInfo*(ptr: pointer): AllocationInfo =
  ## Get information about allocation
  for i in 0..<gTrackerCount:
    if gAllocationTracker[i].address == ptr:
      return gAllocationTracker[i]
  return AllocationInfo()

# ═══════════════════════════════════════════════════════════════════════════
# Allocator Statistics
# ═══════════════════════════════════════════════════════════════════════════

proc getAllocatorStats*(): AllocatorStats =
  ## Get current allocator statistics
  if gCurrentAllocator.getStats != nil:
    return gCurrentAllocator.getStats()
  return AllocatorStats()

proc getTrackedMemory*(): tuple[total: uint64, allocated: uint64] =
  ## Get total tracked memory statistics
  var total: uint64 = 0
  for i in 0..<gTrackerCount:
    total += gAllocationTracker[i].size
  return (total, total)

proc allocatorStats*(): string =
  ## Return formatted allocator statistics
  let stats = getAllocatorStats()
  "Allocator: " & $stats.allocType &
  " | Total: " & $stats.totalMemory &
  " | Used: " & $stats.usedMemory &
  " | Free: " & $stats.freeMemory &
  " | Fragmentation: " & $stats.fragmentationPercent & "%"

proc defragmentMemory*(): bool =
  ## Attempt to defragment current allocator
  if gCurrentAllocator.defragment != nil:
    return gCurrentAllocator.defragment()
  return false

# ═══════════════════════════════════════════════════════════════════════════
# Allocation Debugging
# ═══════════════════════════════════════════════════════════════════════════

proc validateAllAllocations*(): bool =
  ## Validate all tracked allocations
  # Would check each allocation for corruption
  true

proc dumpMemoryUsage*(): string =
  ## Dump detailed memory usage information
  var result = "Memory Usage:\n"
  let tracked = getTrackedMemory()
  result &= "Tracked: " & $tracked.total & " bytes in " & $gTrackerCount & " allocations\n"
  for i in 0..<gTrackerCount:
    result &= "  [" & toHex(uint64(gAllocationTracker[i].address)) & "]: " &
              $gAllocationTracker[i].size & " bytes\n"
  return result
