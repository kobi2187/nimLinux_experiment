# SPDX-License-Identifier: GPL-2.0
## Tests for the display ABI's request checks (kernel/display/display_checks.nim).
import ../kernel/display/display_checks

proc rect(stride: uint32; sx, sy, w, h, dx, dy: int32): PresentRect =
  PresentRect(stride: stride, sx: sx, sy: sy, w: w, h: h, dx: dx, dy: dy)

proc testAccepts() =
  # a 640x400 buffer shown at (100, 50) on a 1280x800 display
  const buf = 640 * 400 * 4
  assert checkPresent(rect(2560, 0, 0, 640, 400, 100, 50), buf, 1280, 800) == deOk
  assert checkPresent(rect(2560, 0, 0, 1, 1, 0, 0), buf, 1280, 800) == deOk, "one pixel"
  assert checkPresent(rect(2560, 639, 399, 1, 1, 1279, 799), buf, 1280, 800) == deOk, "last pixel to last pixel"
  assert checkPresent(rect(2560, 10, 20, 100, 30, 5, 6), buf, 1280, 800) == deOk, "a sub-rect"
  echo "PASS: valid requests accepted"

proc testRefuses() =
  const buf = 640 * 400 * 4
  assert checkPresent(rect(2560, 0, 0, 0, 10, 0, 0), buf, 1280, 800) == deBadRect, "zero width"
  assert checkPresent(rect(2560, 0, 0, 10, -1, 0, 0), buf, 1280, 800) == deBadRect, "negative height"
  assert checkPresent(rect(2560, -1, 0, 10, 10, 0, 0), buf, 1280, 800) == deBadRect, "negative source x"
  assert checkPresent(rect(2560, 0, 0, 10, 10, -5, 0), buf, 1280, 800) == deBadRect, "negative destination"
  assert checkPresent(rect(2561, 0, 0, 10, 10, 0, 0), buf, 1280, 800) == deBadStride, "stride not a pixel multiple"
  assert checkPresent(rect(100, 0, 0, 640, 10, 0, 0), buf, 1280, 800) == deBadStride, "row wider than the stride"
  assert checkPresent(rect(2560, 0, 0, 640, 401, 0, 0), buf, 1280, 800) == deOutOfBuffer, "one row past the buffer"
  assert checkPresent(rect(2560, 600, 0, 41, 1, 0, 0), buf, 1280, 800) == deBadStride, "x range wider than the row"
  assert checkPresent(rect(2560, 0, 0, 640, 400, 641, 0), buf, 1280, 800) == deOutOfDisplay, "off the right edge"
  assert checkPresent(rect(2560, 0, 0, 640, 400, 0, 401), buf, 1280, 800) == deOutOfDisplay, "off the bottom edge"
  echo "PASS: bad requests refused, each with its reason"

proc testNoOverflow() =
  ## Hostile 32-bit values must not wrap into a request that looks valid.
  const big = high(int32)
  assert checkPresent(rect(high(uint32) - 3, 0, big, 1, 1, 0, 0), 1 shl 20, 1280, 800) != deOk, "huge sy"
  assert checkPresent(rect(2560, 0, 0, big, big, 0, 0), 1 shl 20, 1280, 800) != deOk, "huge w, h"
  assert checkPresent(rect(2560, big, big, big, big, big, big), 1 shl 20, 1280, 800) != deOk, "everything huge"
  assert checkPresent(rect(2560, 0, 0, 1, 1, big, big), 1 shl 20, 1280, 800) == deOutOfDisplay, "huge destination"
  assert bufferBytesNeeded(rect(high(uint32) - 3, 0, big, 1, 1, 0, 0)) > int64(1) shl 40, "64-bit arithmetic"
  echo "PASS: 32-bit extremes cannot wrap"

proc testInRange() =
  assert inRange(100, 10, 100, 200) and inRange(190, 10, 100, 200), "edges inside"
  assert not inRange(190, 11, 100, 200), "one byte past the end"
  assert not inRange(99, 1, 100, 200), "one byte before"
  assert not inRange(100, 0, 100, 200), "empty range"
  assert not inRange(high(uint64) - 4, 16, 100, 200), "wrap-around"
  assert not inRange(150, high(uint64), 100, 200), "huge length"
  echo "PASS: user range check"

when isMainModule:
  testAccepts()
  testRefuses()
  testNoOverflow()
  testInRange()
  echo "All display check tests passed."
