# SPDX-License-Identifier: GPL-2.0
## Tests for the virtual region allocator (host-side, no hardware needed)

import ../mm/region_allocator

proc resetAlloc() =
  regionAllocInit()

proc testAllocBasic() =
  resetAlloc()
  let h = regionAlloc(4096'u64)
  assert regionValid(h), "freshly allocated handle must be valid"
  assert regionBase(h) == RegionBase, "first slot base must equal RegionBase"
  echo "PASS: basic alloc returns valid handle at RegionBase"

proc testFreeAndReuse() =
  resetAlloc()
  let h0 = regionAlloc(4096'u64)
  assert regionValid(h0)
  let slot0 = int(h0)
  regionFree(h0)
  let h1 = regionAlloc(4096'u64)
  assert regionValid(h1), "alloc after free must succeed"
  assert int(h1) == slot0, "freed slot must be reused"
  echo "PASS: free then alloc reuses the same slot"

proc testExhaustPool() =
  resetAlloc()
  for i in 0 ..< MaxRegions:
    let h = regionAlloc(1024'u64)
    assert regionValid(h), "slot " & $i & " should be valid"
  # One more must fail
  let hExtra = regionAlloc(1024'u64)
  assert not regionValid(hExtra), "alloc beyond MaxRegions must return invalid"
  echo "PASS: alloc beyond MaxRegions returns invalid handle"

proc testOversizedAlloc() =
  resetAlloc()
  let hBig = regionAlloc(RegionSize + 1)
  assert not regionValid(hBig), "alloc larger than RegionSize must fail"
  echo "PASS: alloc with size > RegionSize returns invalid handle"

when isMainModule:
  testAllocBasic()
  testFreeAndReuse()
  testExhaustPool()
  testOversizedAlloc()
  echo "All region allocator tests passed."
