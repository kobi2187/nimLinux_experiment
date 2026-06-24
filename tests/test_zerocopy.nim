# SPDX-License-Identifier: GPL-2.0
## Tests for capGrantRegion, regionAddRef/DecRef, and memory capability rights.

import ../kernel/cap/capability
import ../mm/region_allocator

proc setup() =
  regionAllocInit()
  capTableInit()
  # Allocate one region slot so slot 0 is valid
  discard regionAlloc(4096)

proc testGrantRegionValidSlotReturnsNonNull() =
  setup()
  let tok = capGrantRegion(0, 1, capMemRead)
  assert not tok.isNull, "capGrantRegion for valid slot must return non-null token"
  echo "PASS: capGrantRegion valid slot returns non-null token"

proc testRefCountOneAfterGrant() =
  setup()
  discard capGrantRegion(0, 1, capMemRead)
  assert regionRefCount(RegionHandle(0)) == 1, "ref count must be 1 after one grant"
  echo "PASS: ref count is 1 after first grant"

proc testRefCountTwoAfterSecondGrant() =
  setup()
  discard capGrantRegion(0, 1, capMemRead)
  discard capGrantRegion(0, 2, capMemRead)
  assert regionRefCount(RegionHandle(0)) == 2, "ref count must be 2 after two grants"
  echo "PASS: ref count is 2 after second grant"

proc testRefCountDropsToOneAfterFirstRevoke() =
  setup()
  let tok1 = capGrantRegion(0, 1, capMemRead)
  discard capGrantRegion(0, 2, capMemRead)
  capRevoke(tok1)
  assert regionRefCount(RegionHandle(0)) == 1, "ref count must drop to 1 after first revoke"
  echo "PASS: ref count drops to 1 after first revoke"

proc testRefCountDropsToZeroAfterBothRevoked() =
  setup()
  let tok1 = capGrantRegion(0, 1, capMemRead)
  let tok2 = capGrantRegion(0, 2, capMemRead)
  capRevoke(tok1)
  capRevoke(tok2)
  assert regionRefCount(RegionHandle(0)) == 0, "ref count must drop to 0 after both revoked"
  echo "PASS: ref count drops to 0 after both tokens revoked"

proc testGrantRegionInvalidSlotReturnsNullCap() =
  setup()
  let tok = capGrantRegion(99, 1, capMemRead)
  assert tok.isNull, "capGrantRegion for invalid slot must return NullCap"
  echo "PASS: capGrantRegion invalid slot returns NullCap"

proc testGrantRegionMemWriteCapCheckPasses() =
  setup()
  let tok = capGrantRegion(0, 1, capMemWrite)
  assert not tok.isNull, "capGrantRegion with capMemWrite must return non-null token"
  assert capCheck(tok, capMemWrite), "capCheck must pass for capMemWrite"
  echo "PASS: capGrantRegion with capMemWrite grants write right, capCheck passes"

when isMainModule:
  testGrantRegionValidSlotReturnsNonNull()
  testRefCountOneAfterGrant()
  testRefCountTwoAfterSecondGrant()
  testRefCountDropsToOneAfterFirstRevoke()
  testRefCountDropsToZeroAfterBothRevoked()
  testGrantRegionInvalidSlotReturnsNullCap()
  testGrantRegionMemWriteCapCheckPasses()
  echo "All zerocopy/region-cap tests passed."
