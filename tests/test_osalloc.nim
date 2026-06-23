# SPDX-License-Identifier: GPL-2.0
## Tests for osalloc.nim — stdlib alloc shim
## Compiled with -d:testing so nimixAllocRegion/nimixFreeRegion use host alloc.

import ../kernel/abi/osalloc

proc testAllocMemNonNil() =
  let p = allocMem(64)
  assert p != nil, "allocMem(64) should return non-nil"
  deallocMem(p, 64)
  echo "PASS: allocMem returns non-nil for size > 0"

proc testDeallocMemNoCrash() =
  let p = allocMem(32)
  assert p != nil
  deallocMem(p, 32)
  echo "PASS: deallocMem doesn't crash"

proc testReallocMemCopiesData() =
  let p = allocMem(8)
  assert p != nil
  let arr = cast[ptr UncheckedArray[byte]](p)
  for i in 0 ..< 8: arr[i] = byte(i + 1)
  let q = reallocMem(p, 8, 16)
  assert q != nil, "reallocMem should return non-nil"
  let arr2 = cast[ptr UncheckedArray[byte]](q)
  for i in 0 ..< 8:
    assert arr2[i] == byte(i + 1), "data not copied at index " & $i
  deallocMem(q, 16)
  echo "PASS: reallocMem copies data correctly"

proc testAllocMemZero() =
  ## allocMem(0) behavior is implementation-defined; may return nil. Document only.
  let p = allocMem(0)
  # p may be nil — that is acceptable
  if p != nil:
    deallocMem(p, 0)
  echo "PASS: allocMem(0) is acceptable (nil or non-nil)"

when isMainModule:
  testAllocMemNonNil()
  testDeallocMemNoCrash()
  testReallocMemCopiesData()
  testAllocMemZero()
  echo "All osalloc tests passed."
