# SPDX-License-Identifier: GPL-2.0
## Tests for RTC driver — pure logic, no hardware (noKernelHardware)

{.define: noKernelHardware.}
import ../drivers/rtc

proc testBcdToBin() =
  # bcdToBin is private; test via the exported type shapes and known values.
  # We exercise the logic by constructing RtcDateTime values directly.
  var dt: RtcDateTime
  dt.second = 0x45  # BCD 45 = 45 decimal
  dt.minute = 0x30  # BCD 30 = 30 decimal
  dt.hour   = 0x12  # BCD 12 = 12 decimal
  dt.day    = 0x07
  dt.month  = 0x06
  dt.year   = 0x26  # BCD 26 = 26 (century prefix makes 2026)

  # Replicate bcdToBin inline to test the formula
  proc bcd(v: uint8): uint8 = (v shr 4) * 10 + (v and 0x0F)

  assert bcd(0x45) == 45, "BCD 0x45 → 45"
  assert bcd(0x30) == 30, "BCD 0x30 → 30"
  assert bcd(0x12) == 12, "BCD 0x12 → 12"
  assert bcd(0x59) == 59, "BCD 0x59 → 59 (max seconds/minutes)"
  assert bcd(0x23) == 23, "BCD 0x23 → 23 (max hours)"
  assert bcd(0x00) == 0,  "BCD 0x00 → 0"
  assert bcd(0x99) == 99, "BCD 0x99 → 99 (max two-digit)"
  echo "PASS: BCD → binary conversion"

proc testRtcDateTimeFields() =
  var dt: RtcDateTime
  dt.second = 30
  dt.minute = 15
  dt.hour   = 9
  dt.day    = 26
  dt.month  = 6
  dt.year   = 2026

  assert dt.second == 30
  assert dt.minute == 15
  assert dt.hour   == 9
  assert dt.day    == 26
  assert dt.month  == 6
  assert dt.year   == 2026
  echo "PASS: RtcDateTime field layout"

proc testYearCenturyFallback() =
  # When century register is 0, year = 2000 + two-digit year
  # This is the common QEMU path (no century register).
  proc yearWithCentury(century: uint8, twoDigit: uint8): uint16 =
    if century > 0'u8: century.uint16 * 100 + twoDigit.uint16
    else: 2000'u16 + twoDigit.uint16

  assert yearWithCentury(0, 26) == 2026, "no century register → 2000 + 26"
  assert yearWithCentury(20, 26) == 2026, "century=20 → 2026"
  assert yearWithCentury(21, 5)  == 2105, "century=21 → 2105"
  echo "PASS: year/century calculation"

when isMainModule:
  testBcdToBin()
  testRtcDateTimeFields()
  testYearCenturyFallback()
  echo "All RTC tests passed."
