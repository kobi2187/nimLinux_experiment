# SPDX-License-Identifier: GPL-2.0
## Allocator trait - LAYER 0
##
## Defines the interface that any memory allocator must implement.
## This enables polymorphic memory allocation strategies.

import ../types

type
  # ═══════════════════════════════════════════════════════════════════════════
  # Allocator Error Types
  # ═══════════════════════════════════════════════════════════════════════════

  AllocError* = enum
    ## Errors that can occur during memory allocation
    aeNone = 0
    aeOutOfMemory       ## No more memory available
    aeInvalidSize       ## Invalid allocation size requested
    aeInvalidAlignment  ## Invalid alignment requested
    aeDoubleFree        ## Attempted to free already freed memory
    aeInvalidPointer    ## Invalid pointer passed to free/realloc
    aeCorruption        ## Memory corruption detected

  # ═══════════════════════════════════════════════════════════════════════════
  # Allocator Statistics
  # ═══════════════════════════════════════════════════════════════════════════

  AllocStats* = object
    ## Statistics about allocator usage
    totalAllocated*: uint64    ## Total bytes allocated (lifetime)
    totalFreed*: uint64        ## Total bytes freed (lifetime)
    currentUsed*: uint64       ## Current bytes in use
    peakUsed*: uint64          ## Peak bytes used
    allocCount*: uint64        ## Number of allocations
    freeCount*: uint64         ## Number of frees
    failCount*: uint64         ## Number of failed allocations

  # ═══════════════════════════════════════════════════════════════════════════
  # Allocator Interface (using object with function pointers)
  # ═══════════════════════════════════════════════════════════════════════════

  AllocatorVTable* = object
    ## Virtual table for allocator operations
    alloc*: proc(self: pointer, size: uint64): Result[pointer, AllocError] {.nimcall.}
    allocAligned*: proc(self: pointer, size: uint64, align: uint64): Result[pointer, AllocError] {.nimcall.}
    realloc*: proc(self: pointer, p: pointer, newSize: uint64): Result[pointer, AllocError] {.nimcall.}
    free*: proc(self: pointer, p: pointer): Result[void, AllocError] {.nimcall.}
    availableMemory*: proc(self: pointer): uint64 {.nimcall.}
    getStats*: proc(self: pointer): AllocStats {.nimcall.}

  Allocator* = object
    ## Generic allocator wrapper
    vtable*: ptr AllocatorVTable
    impl*: pointer

# ═══════════════════════════════════════════════════════════════════════════
# Allocator Operations
# ═══════════════════════════════════════════════════════════════════════════

proc alloc*(a: Allocator, size: uint64): Result[pointer, AllocError] {.inline.} =
  ## Allocate memory
  a.vtable.alloc(a.impl, size)

proc allocAligned*(a: Allocator, size: uint64, align: uint64): Result[pointer, AllocError] {.inline.} =
  ## Allocate aligned memory
  a.vtable.allocAligned(a.impl, size, align)

proc realloc*(a: Allocator, p: pointer, newSize: uint64): Result[pointer, AllocError] {.inline.} =
  ## Reallocate memory
  a.vtable.realloc(a.impl, p, newSize)

proc free*(a: Allocator, p: pointer): Result[void, AllocError] {.inline.} =
  ## Free memory
  a.vtable.free(a.impl, p)

proc availableMemory*(a: Allocator): uint64 {.inline.} =
  ## Get available memory
  a.vtable.availableMemory(a.impl)

proc getStats*(a: Allocator): AllocStats {.inline.} =
  ## Get allocator statistics
  a.vtable.getStats(a.impl)

# ═══════════════════════════════════════════════════════════════════════════
# Typed Allocation Helpers
# ═══════════════════════════════════════════════════════════════════════════

proc allocTyped*[T](a: Allocator): Result[ptr T, AllocError] =
  ## Allocate memory for a single object of type T
  let res = a.alloc(sizeof(T).uint64)
  if res.isOk:
    ok(cast[ptr T](res.value))
  else:
    err[ptr T, AllocError](res.error)

proc allocArray*[T](a: Allocator, count: uint64): Result[ptr UncheckedArray[T], AllocError] =
  ## Allocate memory for an array of objects
  let res = a.alloc(sizeof(T).uint64 * count)
  if res.isOk:
    ok(cast[ptr UncheckedArray[T]](res.value))
  else:
    err[ptr UncheckedArray[T], AllocError](res.error)

proc freeTyped*[T](a: Allocator, p: ptr T): Result[void, AllocError] {.inline.} =
  ## Free typed memory
  a.free(cast[pointer](p))

# ═══════════════════════════════════════════════════════════════════════════
# Allocation Flags
# ═══════════════════════════════════════════════════════════════════════════

type
  AllocFlags* = distinct uint32
    ## Flags for allocation requests

const
  afNone*: AllocFlags = 0.AllocFlags
  afZero*: AllocFlags = 1.AllocFlags      ## Zero-initialize memory
  afNoWait*: AllocFlags = 2.AllocFlags    ## Don't wait/block
  afDma*: AllocFlags = 4.AllocFlags       ## DMA-safe allocation
  afDma32*: AllocFlags = 8.AllocFlags     ## 32-bit DMA region

proc `or`*(a, b: AllocFlags): AllocFlags {.inline.} =
  AllocFlags(uint32(a) or uint32(b))

proc `and`*(a, b: AllocFlags): AllocFlags {.inline.} =
  AllocFlags(uint32(a) and uint32(b))

proc contains*(a, b: AllocFlags): bool {.inline.} =
  (uint32(a) and uint32(b)) == uint32(b)
