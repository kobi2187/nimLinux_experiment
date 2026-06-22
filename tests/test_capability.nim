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

when isMainModule:
  testNullCapIsNull()
  testDifferentTokensNotEqual()
  testNonZeroTokenNotNull()
  echo "All capability tests passed."
