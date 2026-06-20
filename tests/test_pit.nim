# SPDX-License-Identifier: GPL-2.0
## Tests for PIT 8253/8254 — pure logic, no hardware

import ../drivers/pit

proc testDivisorCalc() =
  let d100  = pitDivisor(100)
  let d1000 = pitDivisor(1000)
  # PIT base = 1,193,182 Hz
  assert d100  >= 11931 and d100  <= 11932, "100Hz divisor ~11931"
  assert d1000 >= 1193  and d1000 <= 1194,  "1000Hz divisor ~1193"
  echo "PASS: PIT divisor calculation"

proc testTickCounter() =
  resetTicks()
  assert pitTicks() == 0, "starts at 0 after reset"
  pitTick()
  assert pitTicks() == 1, "increments to 1"
  pitTick()
  assert pitTicks() == 2, "increments to 2"
  resetTicks()
  assert pitTicks() == 0, "resets to 0"
  echo "PASS: tick counter"

when isMainModule:
  testDivisorCalc()
  testTickCounter()
  echo "All PIT tests passed."
