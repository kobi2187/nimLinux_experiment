# SPDX-License-Identifier: GPL-2.0
## Unit tests for the per-SIP bump allocator (host-side, no hardware needed).

import ../mm/sip_heap
import ../mm/region_allocator

proc testBasicAlloc() =
  regionAllocInit()
  let h = regionAlloc(RegionSize)
  assert regionValid(h)
  let slot = int(h)
  sipHeapInit(slot)
  let p1 = sipAlloc(slot, 64)
  assert p1 != nil
  let p2 = sipAlloc(slot, 128)
  assert p2 != nil
  assert cast[uint64](p2) > cast[uint64](p1)  # bump grew
  echo "PASS: basic alloc"

proc testAlignment() =
  regionAllocInit()
  let h = regionAlloc(RegionSize)
  let slot = int(h)
  sipHeapInit(slot)
  let p1 = sipAlloc(slot, 1)   # 1 byte must be rounded to 16
  let p2 = sipAlloc(slot, 1)
  assert (cast[uint64](p2) - cast[uint64](p1)) == uint64(MinAllocAlign)
  echo "PASS: alignment"

proc testExhaustion() =
  regionAllocInit()
  let h = regionAlloc(RegionSize)
  let slot = int(h)
  sipHeapInit(slot)
  # Allocate almost everything
  let bigAlloc = sipAlloc(slot, int(RegionSize) - SipHeapHeaderSize - 64)
  assert bigAlloc != nil
  # Next alloc should fail
  let p = sipAlloc(slot, 1024)
  assert p == nil
  echo "PASS: exhaustion returns nil"

proc testInvalidSlot() =
  assert sipAlloc(-1, 64) == nil
  assert sipAlloc(MaxRegions, 64) == nil
  echo "PASS: invalid slot returns nil"

proc testSetBump() =
  regionAllocInit()
  let h = regionAlloc(RegionSize)
  let slot = int(h)
  sipHeapInit(slot)
  let base = regionBase(h)
  # Pretend ELF occupies first 1 MB
  let elfEnd = base + 1024 * 1024
  sipHeapSetBump(slot, elfEnd)
  assert gSipHeaps[slot].bump >= elfEnd
  assert gSipHeaps[slot].bump mod uint64(MinAllocAlign) == 0
  echo "PASS: sipHeapSetBump places bump after ELF"

proc testHostileSizes() =
  ## nimixMapAnon / nimixAllocRegion pass the caller's size straight through.
  regionAllocInit()
  let slot = int(regionAlloc(RegionSize))
  sipHeapInit(slot)
  let before = gSipHeaps[slot].bump
  for bad in [0, -1, -16, -4096, low(int), high(int), int(RegionSize) * 2, int(RegionSize)]:
    assert sipAlloc(slot, bad) == nil, "size " & $bad & " must be refused"
    assert gSipHeaps[slot].bump == before, "a refused size must not move the heap (" & $bad & ")"
  let p = sipAlloc(slot, 64)
  assert p != nil and cast[uint64](p) == before, "the heap still works after the refusals"
  assert sipAlloc(slot, int(RegionSize) - SipHeapHeaderSize - 64) != nil, "exactly the rest is fine"
  assert sipAlloc(slot, 1) == nil, "and then it is full"
  echo "PASS: hostile sizes refused, heap untouched"

when isMainModule:
  testHostileSizes()
  testBasicAlloc()
  testAlignment()
  testExhaustion()
  testInvalidSlot()
  testSetBump()
  echo "All SIP heap tests passed."
