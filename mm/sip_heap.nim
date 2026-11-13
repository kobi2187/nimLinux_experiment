# SPDX-License-Identifier: GPL-2.0
## Per-SIP bump allocator — each app region has its own heap.
## Lives at the start of the region, grows upward.
## Simple and fast: O(1) alloc, no individual free (region freed as a whole).

import region_allocator

const
  SipHeapHeaderSize* = 64   ## Reserved at slot base for heap metadata
  MinAllocAlign*     = 16   ## All allocations 16-byte aligned

type
  SipHeap* = object
    bump*:  uint64   ## next free byte (absolute address)
    limit*: uint64   ## one past end of region
    slot*:  int      ## which region slot this heap belongs to

var gSipHeaps*: array[MaxRegions, SipHeap]

proc sipHeapInit*(slot: int) =
  ## Initialise the bump heap for a freshly allocated region slot.
  ## Starts the heap at slot base + SipHeapHeaderSize.
  let base  = regionBase(RegionHandle(slot))
  let limit = base + RegionSize
  gSipHeaps[slot] = SipHeap(
    bump:  base + uint64(SipHeapHeaderSize),
    limit: limit,
    slot:  slot
  )

proc sipHeapSetBump*(slot: int; afterElf: uint64) =
  ## Set the bump pointer after the ELF binary has been loaded.
  ## `afterElf` = first free byte after all PT_LOAD segments.
  ## Aligns up to MinAllocAlign.
  if slot < 0 or slot >= MaxRegions: return
  let aligned = (afterElf + uint64(MinAllocAlign) - 1) and not (uint64(MinAllocAlign) - 1)
  gSipHeaps[slot].bump = aligned

proc sipAlloc*(slot: int; size: int): pointer =
  ## Bump-allocate `size` bytes from the SIP's region heap.
  ## Returns nil if out of space, or if `size` is not positive. `size` comes from ring 3
  ## (nimixMapAnon / nimixAllocRegion): a negative one used to wrap the arithmetic below and
  ## move the bump pointer BACKWARDS, so later allocations overlapped earlier ones.
  if slot < 0 or slot >= MaxRegions or size <= 0: return nil
  let h = addr gSipHeaps[slot]
  let room = h.limit - h.bump                      # h.bump <= h.limit always
  if uint64(size) > room: return nil               # also keeps the alignment round-up below from wrapping
  let aligned = (uint64(size) + uint64(MinAllocAlign) - 1) and not (uint64(MinAllocAlign) - 1)
  if aligned > room: return nil
  result = cast[pointer](h.bump)
  h.bump += aligned

proc sipFree*(slot: int; p: pointer; size: int) =
  ## No-op: bump allocators don't free individually.
  ## The whole region is freed when the app exits.
  discard

proc sipHeapFree*(slot: int): uint64 =
  ## Bytes remaining in this SIP's heap.
  if slot < 0 or slot >= MaxRegions: return 0
  gSipHeaps[slot].limit - gSipHeaps[slot].bump
