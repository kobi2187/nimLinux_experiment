# SPDX-License-Identifier: GPL-2.0
## Virtual Region Allocator
##
## Hands out non-overlapping virtual address ranges for apps/SIPs.
## Used by the ELF loader so each loaded binary lands at its own address.
##
## Layout (all models share this map in SASOS; per-process in mono/micro):
##
##   0x000000 - RegionBase-1   kernel image + heap (untouchable)
##   RegionBase + 0*RegionSize  slot 0  (first app)
##   RegionBase + 1*RegionSize  slot 1  (second app)
##   ...
##
## Simple bump allocator: regions are never freed during a session.
## A freed slot is returned to a small free-list for reuse.

import ../core/log

const
  RegionBase* = 0x400000'u64      ## First app starts here (4 MB mark)
  RegionSize* = 4 * 1024 * 1024'u64  ## Each slot is 4 MB
  MaxRegions* = 16                ## Max simultaneous loaded apps

type
  RegionHandle* = distinct int    ## Opaque slot index; -1 = invalid

  RegionAllocator* = object
    nextSlot:  int                      ## Next never-used slot index
    freeSlots: array[MaxRegions, int]   ## Freed slots available for reuse
    freeCount: int

var gRegionAlloc*: RegionAllocator   ## Global instance; init by kernel boot

proc regionAllocInit*() =
  gRegionAlloc.nextSlot  = 0
  gRegionAlloc.freeCount = 0

proc regionBase*(h: RegionHandle): uint64 =
  ## Convert a handle to the absolute base address of that slot.
  RegionBase + uint64(int(h)) * RegionSize

proc regionAlloc*(needed: uint64): RegionHandle =
  ## Allocate a slot large enough for `needed` bytes.
  ## Returns an invalid handle (-1) if no slot fits or pool exhausted.
  if needed > RegionSize:
    klogInt(llError, "regionAlloc: app too large, needed=", int64(needed))
    return RegionHandle(-1)

  # Prefer a recycled slot
  if gRegionAlloc.freeCount > 0:
    dec gRegionAlloc.freeCount
    let slot = gRegionAlloc.freeSlots[gRegionAlloc.freeCount]
    klogInt(llInfo, "regionAlloc: reused slot ", int64(slot))
    return RegionHandle(slot)

  if gRegionAlloc.nextSlot >= MaxRegions:
    klog(llError, "regionAlloc: out of region slots")
    return RegionHandle(-1)

  let slot = gRegionAlloc.nextSlot
  inc gRegionAlloc.nextSlot
  klogInt(llInfo, "regionAlloc: allocated slot ", int64(slot))
  return RegionHandle(slot)

proc regionFree*(h: RegionHandle) =
  ## Return a slot to the free list so the next app can reuse it.
  if int(h) < 0: return
  if gRegionAlloc.freeCount < MaxRegions:
    gRegionAlloc.freeSlots[gRegionAlloc.freeCount] = int(h)
    inc gRegionAlloc.freeCount
    klogInt(llInfo, "regionAlloc: freed slot ", int64(int(h)))

proc regionValid*(h: RegionHandle): bool =
  int(h) >= 0

proc regionUsedCount*(): int =
  ## Number of region slots currently in use (allocated minus freed).
  gRegionAlloc.nextSlot - gRegionAlloc.freeCount
