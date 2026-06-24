# SPDX-License-Identifier: GPL-2.0
## Validates that key Nim stdlib modules compile under --os:standalone.
## Run with: nim c -r --skipParentCfg --mm:refc --path:. -d:noSignalHandler tests/test_stdlib_shim.nim

import strutils, options, sequtils, tables, sets, sugar, algorithm, math

proc testStrutils() =
  assert "hello world".split(' ') == @["hello", "world"]
  assert "hello".toUpperAscii == "HELLO"
  assert "  hi  ".strip == "hi"
  echo "PASS: strutils"

proc testOptions() =
  let x = some(42)
  assert x.isSome
  assert x.get == 42
  let y = none(int)
  assert y.isNone
  echo "PASS: options"

proc testSequtils() =
  let doubled = @[1, 2, 3].map(x => x * 2)
  assert doubled == @[2, 4, 6]
  assert @[1, 2, 3, 4].filter(x => x mod 2 == 0) == @[2, 4]
  echo "PASS: sequtils + sugar"

proc testTables() =
  var t = initTable[string, int]()
  t["a"] = 1; t["b"] = 2
  assert t["a"] == 1
  assert t.len == 2
  echo "PASS: tables"

proc testSets() =
  var s = toHashSet([1, 2, 3])
  s.incl(4)
  assert 4 in s
  assert 5 notin s
  echo "PASS: sets"

proc testAlgorithm() =
  var xs = @[3, 1, 4, 1, 5, 9]
  xs.sort()
  assert xs == @[1, 1, 3, 4, 5, 9]
  echo "PASS: algorithm"

proc testMath() =
  assert abs(-5) == 5
  assert max(3, 7) == 7
  echo "PASS: math"

testStrutils()
testOptions()
testSequtils()
testTables()
testSets()
testAlgorithm()
testMath()
echo "All stdlib shim tests passed."
