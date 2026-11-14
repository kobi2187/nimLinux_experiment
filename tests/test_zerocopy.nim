# SPDX-License-Identifier: GPL-2.0
## Region capabilities: who may mint them, and how long the memory lives.
##
## Model: the owner holds one reference from regionAlloc; every region
## capability holds another. regionFree drops the owner's reference and the
## slot is recycled only when the last reference goes. The last three tests
## are regressions for holes found 2026-10-27 (any task could mint a write
## cap on any slot; a freed slot was reused while capabilities still named it).

import ../kernel/cap/capability
import ../mm/region_allocator

var h: RegionHandle

proc setup() =
  regionAllocInit()
  capTableInit()
  h = regionAlloc(4096)                     # slot 0, owned by "pid 1"

proc testGrantRegionValidSlotReturnsNonNull() =
  setup()
  let tok = capGrantRegion(0, 1, capMemRead)
  assert not tok.isNull, "capGrantRegion for valid slot must return non-null token"
  echo "PASS: capGrantRegion valid slot returns non-null token"

proc testOwnerHoldsOneReference() =
  setup()
  assert regionRefCount(h) == 1, "the owner's reference"
  discard capGrantRegion(0, 2, capMemRead)
  discard capGrantRegion(0, 3, capMemRead)
  assert regionRefCount(h) == 3, "owner + two capabilities"
  echo "PASS: owner reference + one per capability"

proc testLastReferenceReleases() =
  setup()
  let t1 = capGrantRegion(0, 2, capMemRead)
  let t2 = capGrantRegion(0, 3, capMemRead)
  regionFree(h)                              # owner done
  capRevoke(t1)
  assert regionValid(h), "still referenced by t2"
  capRevoke(t2)
  assert not regionValid(h) and regionRefCount(h) == 0, "last reference releases"
  echo "PASS: slot released only when the last reference goes"

proc testGrantRegionInvalidSlotReturnsNullCap() =
  setup()
  assert capGrantRegion(99, 1, capMemRead).isNull, "out of range"
  regionFree(h)
  assert capGrantRegion(0, 1, capMemRead).isNull, "freed slot"
  echo "PASS: capGrantRegion on an invalid or freed slot returns NullCap"

proc testGrantRegionMemWriteCapCheckPasses() =
  setup()
  let tok = capGrantRegion(0, 1, capMemWrite)
  assert not tok.isNull and capCheck(tok, capMemWrite)
  echo "PASS: capMemWrite grant passes capCheck"

proc testOnlyOwnerOrGrantHolderMayMint() =
  setup()
  assert capMayGrantRegion(1, ownSlot = 0, slot = 0), "owner may"
  assert not capMayGrantRegion(99, ownSlot = -1, slot = 0), "a stranger may not"
  discard capGrantRegion(0, 99, capMemGrant)
  assert capMayGrantRegion(99, ownSlot = -1, slot = 0), "capMemGrant holder may"
  echo "PASS: only the owner or a capMemGrant holder may mint region caps"

proc testFreedWhileReferencedIsNotReused() =
  setup()
  let reader = capGrantRegion(0, 7, capMemRead)
  regionFree(h)                              # owner exits
  let next = regionAlloc(4096)
  assert int(next) != int(h), "a referenced slot must not go to the next app"
  assert capCheck(reader, capMemRead) and regionValid(h), "reader still sees the same memory"
  echo "PASS: no reuse while a capability still names the slot"

proc testDoubleFreeIgnored() =
  setup()
  regionFree(h)
  regionFree(h)
  let a = regionAlloc(4096)
  let b = regionAlloc(4096)
  assert int(a) != int(b), "a double free must not put the slot on the free list twice"
  echo "PASS: double free ignored"

proc testRevokeAllOfReleasesHeldRegions() =
  setup()
  discard capGrantRegion(0, 5, capMemRead)
  discard capGrantRegion(0, 5, capMemWrite)
  regionFree(h)
  capRevokeAllOf(5)                          # pid 5 exits
  assert not regionValid(h), "exit releases what the task held"
  echo "PASS: task exit revokes its region caps"

when isMainModule:
  testGrantRegionValidSlotReturnsNonNull()
  testOwnerHoldsOneReference()
  testLastReferenceReleases()
  testGrantRegionInvalidSlotReturnsNullCap()
  testGrantRegionMemWriteCapCheckPasses()
  testOnlyOwnerOrGrantHolderMayMint()
  testFreedWhileReferencedIsNotReused()
  testDoubleFreeIgnored()
  testRevokeAllOfReleasesHeldRegions()
  echo "All zerocopy/region-cap tests passed."
