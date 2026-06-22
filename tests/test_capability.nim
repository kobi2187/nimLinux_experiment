# SPDX-License-Identifier: GPL-2.0
## Tests for CapToken and CapRight types (no hardware needed)

import ../kernel/cap/capability

proc testNullCapIsNull() =
  assert isNull(NullCap), "NullCap must be null"
  echo "PASS: NullCap is null"

proc testDifferentTokensNotEqual() =
  let a = CapToken(1)
  let b = CapToken(2)
  assert a != b, "Different token values must not be equal"
  echo "PASS: different token values are not equal"

proc testNonZeroTokenNotNull() =
  let t = CapToken(42)
  assert not isNull(t), "Non-zero token must not be null"
  echo "PASS: isNull returns false for non-zero token"

proc testCapTableInitZeroesEntries() =
  capTableInit()
  for i in 0 ..< MaxCaps:
    let e = gCapTable.entries[i]
    assert not e.valid, "entry " & $i & " must not be valid after init"
    assert isNull(e.token), "entry " & $i & " token must be NullCap after init"
    assert e.pid == 0, "entry " & $i & " pid must be 0 after init"
  echo "PASS: capTableInit zeroes all entries"

proc testMakeTokenEncoding() =
  let t = makeToken(7, 3)
  assert tokenSerial(t) == 7, "serial must be 7"
  assert tokenSlot(t) == 3, "slot must be 3"
  echo "PASS: makeToken encodes slot and serial correctly"

proc testTokenRoundTrip() =
  let serial: uint32 = 0xABCD1234'u32
  let slot = 63
  let t = makeToken(serial, slot)
  assert tokenSerial(t) == serial, "serial round-trip failed"
  assert tokenSlot(t) == slot, "slot round-trip failed"
  echo "PASS: tokenSlot/tokenSerial round-trip"

when isMainModule:
  testNullCapIsNull()
  testDifferentTokensNotEqual()
  testNonZeroTokenNotNull()
  testCapTableInitZeroesEntries()
  testMakeTokenEncoding()
  testTokenRoundTrip()
  echo "All capability tests passed."
