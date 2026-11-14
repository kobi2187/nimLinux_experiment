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
## Lifetime is reference counted: the owner holds one reference from
## regionAlloc, and every region capability holds another (capGrantRegion).
## regionFree drops the owner's reference; the slot is recycled only when
## the LAST reference goes — so a capability can never outlive the memory
## it names, nor alias the next app's memory (use-after-free).

import ../core/log

const
  RegionBase* = 0x2000000'u64      ## First app starts here (32 MB mark)
  RegionSize* = 4 * 1024 * 1024'u64  ## Each slot is 4 MB
  MaxRegions* = 16                ## Max simultaneous loaded apps
  RegionsEnd* = RegionBase + uint64(MaxRegions) * RegionSize   ## 96 MB
  ArenaBase*  = RegionsEnd         ## buffer arena (ipc/buffers) follows the regions

type
  RegionHandle* = distinct int    ## Opaque slot index; -1 = invalid

  RegionAllocator* = object
    nextSlot:  int                      ## Next never-used slot index
    freeSlots: array[MaxRegions, int]   ## Freed slots available for reuse
    freeCount: int

var gRegionAlloc*: RegionAllocator   ## Global instance; init by kernel boot
var gRegionRefCount: array[MaxRegions, int]
var gRegionLive: array[MaxRegions, bool]
var regionOnRelease*: proc(h: RegionHandle) {.nimcall.}
  ## Called once when a slot's last reference goes (user-window revoke).

proc regionAllocInit*() =
  gRegionAlloc.nextSlot  = 0
  gRegionAlloc.freeCount = 0
  for i in 0 ..< MaxRegions:
    gRegionRefCount[i] = 0
    gRegionLive[i] = false

func regionBase*(h: RegionHandle): uint64 =
  ## Convert a handle to the absolute base address of that slot.
  RegionBase + uint64(int(h)) * RegionSize

proc claim(slot: int): RegionHandle =
  gRegionLive[slot] = true
  gRegionRefCount[slot] = 1          # the owner's reference
  RegionHandle(slot)

proc regionAlloc*(needed: uint64): RegionHandle =
  ## Allocate a slot large enough for `needed` bytes; the caller holds its
  ## one owner reference. Returns an invalid handle (-1) if no slot fits.
  if needed > RegionSize:
    klogInt(llError, "regionAlloc: app too large, needed=", int64(needed))
    return RegionHandle(-1)

  # Prefer a recycled slot
  if gRegionAlloc.freeCount > 0:
    dec gRegionAlloc.freeCount
    let slot = gRegionAlloc.freeSlots[gRegionAlloc.freeCount]
    klogInt(llInfo, "regionAlloc: reused slot ", int64(slot))
    return claim(slot)

  if gRegionAlloc.nextSlot >= MaxRegions:
    klog(llError, "regionAlloc: out of region slots")
    return RegionHandle(-1)

  let slot = gRegionAlloc.nextSlot
  inc gRegionAlloc.nextSlot
  klogInt(llInfo, "regionAlloc: allocated slot ", int64(slot))
  claim(slot)

proc regionValid*(h: RegionHandle): bool =
  ## True while the slot is allocated (some reference is still held).
  int(h) >= 0 and int(h) < MaxRegions and gRegionLive[int(h)]

proc release(slot: int) =
  ## Last reference gone: recycle the slot.
  gRegionLive[slot] = false
  if regionOnRelease != nil: regionOnRelease(RegionHandle(slot))
  if gRegionAlloc.freeCount < MaxRegions:
    gRegionAlloc.freeSlots[gRegionAlloc.freeCount] = slot
    inc gRegionAlloc.freeCount
    klogInt(llInfo, "regionAlloc: freed slot ", int64(slot))

proc regionAddRef*(h: RegionHandle) =
  if regionValid(h):
    inc gRegionRefCount[int(h)]

proc regionDecRef*(h: RegionHandle): bool =
  ## Drop one reference; true if it was the last (the slot is now recycled).
  if not regionValid(h): return false
  dec gRegionRefCount[int(h)]
  if gRegionRefCount[int(h)] > 0: return false
  release(int(h))
  true

proc regionFree*(h: RegionHandle) =
  ## The owner is done with the slot: drop the owner's reference. The memory
  ## stays allocated while capabilities on it remain. Double free: ignored.
  discard regionDecRef(h)

proc regionUsedCount*(): int =
  ## Number of region slots currently allocated.
  for live in gRegionLive:
    if live: inc result

proc regionRefCount*(h: RegionHandle): int =
  if int(h) < 0 or int(h) >= MaxRegions: return 0
  gRegionRefCount[int(h)]
