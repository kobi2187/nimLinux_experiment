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

proc testCapGrantReturnsNonNull() =
  capTableInit()
  let tok = capGrant(1, capIpc)
  assert not isNull(tok), "capGrant must return a non-null token"
  echo "PASS: capGrant returns non-null token"

proc testCapCheckPassesForCorrectRight() =
  capTableInit()
  let tok = capGrant(1, capIpc)
  assert capCheck(tok, capIpc), "capCheck must pass for correct right"
  echo "PASS: capCheck passes for correct right"

proc testCapCheckFailsForWrongRight() =
  capTableInit()
  let tok = capGrant(1, capIpc)
  assert not capCheck(tok, capFs), "capCheck must fail for wrong right"
  echo "PASS: capCheck fails for wrong right"

proc testCapCheckFailsAfterRevoke() =
  capTableInit()
  let tok = capGrant(1, capIpc)
  capRevoke(tok)
  assert not capCheck(tok, capIpc), "capCheck must fail after revoke"
  echo "PASS: capCheck fails after capRevoke"

proc testDoubleRevokeIsSafe() =
  capTableInit()
  let tok = capGrant(1, capIpc)
  capRevoke(tok)
  capRevoke(tok)  # must not crash
  assert not capCheck(tok, capIpc)
  echo "PASS: double-revoke is safe"

proc testCapGrantFullTableReturnsNullCap() =
  capTableInit()
  for i in 0 ..< MaxCaps:
    discard capGrant(uint32(i), capIpc)
  let tok = capGrant(99, capIpc)
  assert isNull(tok), "capGrant on full table must return NullCap"
  echo "PASS: capGrant returns NullCap when table is full"

proc testNullCapFailsCapCheck() =
  capTableInit()
  assert not capCheck(NullCap, capIpc), "NullCap must fail capCheck for capIpc"
  echo "PASS: NullCap fails capCheck for capIpc"

proc testGrantCheckSucceeds() =
  capTableInit()
  let tok = capGrant(42, capIpc)
  assert not isNull(tok), "capGrant must return non-null token"
  assert capCheck(tok, capIpc), "capGrant+capCheck must succeed"
  echo "PASS: capGrant+capCheck succeeds"

proc testGrantOnZeroInitTable() =
  ## The kernel never calls capTableInit: a zero-initialised table must still
  ## mint a non-null first token (serial 0 + slot 0 would encode NullCap).
  gCapTable = default(CapTable)
  let tok = capGrant(7, capIpc)
  assert not isNull(tok), "first grant on zero-init table must be non-null"
  assert capCheck(tok, capIpc), "first grant on zero-init table must check"
  echo "PASS: capGrant on zero-initialised table"

when isMainModule:
  testNullCapIsNull()
  testDifferentTokensNotEqual()
  testNonZeroTokenNotNull()
  testCapTableInitZeroesEntries()
  testMakeTokenEncoding()
  testTokenRoundTrip()
  testCapGrantReturnsNonNull()
  testCapCheckPassesForCorrectRight()
  testCapCheckFailsForWrongRight()
  testCapCheckFailsAfterRevoke()
  testDoubleRevokeIsSafe()
  testCapGrantFullTableReturnsNullCap()
  testNullCapFailsCapCheck()
  testGrantOnZeroInitTable()
  testGrantCheckSucceeds()
  echo "All capability tests passed."
