# SPDX-License-Identifier: GPL-2.0
## Tests for core/tsc_clock — fixed-point TSC -> nanoseconds, pure math.
## The reference is an exact 128-bit multiply/divide done in C, so the clock is
## checked against the true answer, not against itself.

import std/[strutils, parseutils]
import ../core/tsc_clock

proc exactMulDiv(a, b, c: uint64): uint64 =
  ## floor(a*b/c) with a 128-bit intermediate.
  {.emit: "`result` = (unsigned long long)(((unsigned __int128)`a` * `b`) / `c`);".}

const
  Freqs: array[11, uint64] = [1_000_000'u64, 99_999_999'u64, 1_000_000_000'u64, 1_000_000_001'u64, 1_800_000_000'u64,
           2_399_999_999'u64, 2_994_321_772'u64, 3_500_000_000'u64, 4_700_000_000'u64,
           10_000_000_000'u64, 100_000_000_000'u64]
  Spans: array[8, uint64] = [1'u64, 1_000'u64, 1_000_000'u64, NsPerSec, 3600'u64 * NsPerSec,
           86_400'u64 * NsPerSec, 365'u64 * 86_400'u64 * NsPerSec, 100'u64 * 365'u64 * 86_400'u64 * NsPerSec]

proc testMultiplierFits() =
  for hz in Freqs:
    let c = newTscClock(0, hz)
    assert c.valid, "valid for " & $hz
    assert c.shift >= 1 and c.shift <= 32, "shift in range for " & $hz
  echo "PASS: multiplier and shift for 1 MHz .. 100 GHz"

proc testRejectsImplausible() =
  assert not newTscClock(0, 0).valid
  assert not newTscClock(0, MinTscHz - 1).valid
  assert not newTscClock(0, MaxTscHz + 1).valid
  assert clockNanos(newTscClock(0, 0), 123456) == 0, "invalid clock reads 0"
  echo "PASS: implausible frequencies rejected"

proc testAccuracyAcrossSpans() =
  ## Against the exact answer: relative error within the multiplier's own
  ## quantisation (1/mul) plus one nanosecond, for spans from 1 ns to 100 years.
  var worstPpb = 0'u64
  for hz in Freqs:
    let base = 0x1234_5678_9ABC'u64          # nonzero base: only the delta matters
    let c = newTscClock(base, hz)
    for ns in Spans:
      let cycles = exactMulDiv(ns, hz, NsPerSec)
      if cycles == 0: continue
      if cycles >= (1'u64 shl 63): continue    # beyond what a TSC would reach
      let got = clockNanos(c, base + cycles)
      let truth = exactMulDiv(cycles, NsPerSec, hz)   # what `cycles` really is
      let err = if got > truth: got - truth else: truth - got
      # The multiplier is rounded, so the relative error is at most 0.5/mul;
      # allow 1/mul (+1 ns). For realistic rates (<= 10 GHz) mul > 4e8, i.e.
      # under 2.5e-9: pin that separately.
      let bound = truth div uint64(c.mul) + 1
      if hz <= 10_000_000_000'u64:
        assert err <= truth div 400_000_000'u64 + 1, "realistic rates: 2.5e-9"
      assert err <= bound, "hz=" & $hz & " ns=" & $ns & " got=" & $got &
        " truth=" & $truth
      if truth >= NsPerSec and hz <= 10_000_000_000'u64:   # >= 1 s, realistic rates
        worstPpb = max(worstPpb, err * 1_000_000_000'u64 div truth)
  echo "PASS: accuracy 1 ns..100 y, 1 MHz..100 GHz (worst ", worstPpb,
    " ppb over spans >= 1 s at <= 10 GHz)"

proc testMonotonicAndClamped() =
  let c = newTscClock(1000, 3_000_000_000'u64)
  assert clockNanos(c, 0) == 0, "before base is 0"
  assert clockNanos(c, 1000) == 0, "at base is 0"
  var last = 0'u64
  var tsc = 1000'u64
  var step = 1'u64
  for _ in 0 ..< 100_000:                   # growing steps up to ~2^40 cycles
    tsc += step
    step = (step * 3 + 1) mod (1'u64 shl 40)
    let n = clockNanos(c, tsc)
    assert n >= last, "never goes backwards"
    last = n
  echo "PASS: monotonic, clamped before base"

proc testTscWrapsHighHalf() =
  ## deltas above 2^32 cycles exercise the high-half product.
  let c = newTscClock(0, 2_000_000_000'u64)
  let d = (1'u64 shl 40) + 12345
  let truth = exactMulDiv(d, NsPerSec, 2_000_000_000'u64)
  let got = clockNanos(c, d)
  assert (if got > truth: got - truth else: truth - got) <= 2,
    "high half exact: " & $got & " vs " & $truth
  echo "PASS: deltas above 2^32 cycles"

proc testCalibrationWindow() =
  ## Simulate a PIT channel-2 window of ~30 ms on several TSC rates, with up
  ## to 2000 cycles of polling jitter; the measured frequency lands within
  ## 0.01 % and the resulting clock reads the window back within 0.01 %.
  const counts = 35795'u16                  # ~30 ms
  let windowNs = pitWindowNanos(counts)
  assert windowNs > 29_990_000'u64 and windowNs < 30_010_000'u64
  for hz in [1_000_000_000'u64, 2_400_000_000'u64, 2_994_321_772'u64, 4_700_000_000'u64]:
    for jitter in [0'u64, 1, 700, 2000]:
      let cycles = exactMulDiv(windowNs, hz, NsPerSec) + jitter
      let measured = measuredHz(cycles, windowNs)
      let err = if measured > hz: measured - hz else: hz - measured
      assert err * 10_000 <= hz, "within 0.01%: hz=" & $hz & " got " & $measured
      let c = newTscClock(0, measured)
      let back = clockNanos(c, cycles)
      assert (if back > windowNs: back - windowNs else: windowNs - back) * 10_000 <=
        windowNs, "window reads back"
  echo "PASS: PIT-window calibration within 0.01 %"

proc testMeasurementGuards() =
  assert measuredHz(0, 20_000_000) == 0
  assert measuredHz(1000, 0) == 0
  assert measuredHz(100, 30_000_000) == 0, "implausibly slow"
  assert measuredHz(19_000_000_000'u64, 30_000_000) == 0, "overflow guard"
  echo "PASS: measurement guards"

proc testMedianOf() =
  assert medianOf([]) == 0, "no samples"
  assert medianOf([7'u64]) == 7
  for (a, b, c) in [(1'u64, 2'u64, 3'u64), (3'u64, 2'u64, 1'u64), (2'u64, 1'u64, 3'u64),
                    (2'u64, 3'u64, 1'u64), (1'u64, 3'u64, 2'u64), (3'u64, 1'u64, 2'u64)]:
    assert medianOf([a, b, c]) == 2
  assert medianOf([5'u64, 5, 9]) == 5
  assert medianOf([7'u64, 7, 7]) == 7
  assert medianOf([4'u64, 1, 3, 2]) == 3, "even count: upper middle"
  assert medianOf([9'u64, 1, 5, 3, 7]) == 5
  # outliers on both sides (an interrupted window, a late start) don't move it
  assert medianOf([2_000_000'u64, 9_999_999_999'u64, 2_000_100, 1, 2_000_050]) == 2_000_050
  var big: seq[uint64]
  for i in 0 ..< 40: big.add uint64(40 - i)
  assert medianOf(big) == medianOf(big[0 ..< 15]), "capped at 15 samples"
  echo "PASS: median"

proc testTimePage() =
  # The layout is ABI (apps read it at TimePageAddr): pin every offset.
  assert sizeof(TimePage) == 40
  assert offsetOf(TimePage, magic) == 0 and offsetOf(TimePage, version) == 8
  assert offsetOf(TimePage, valid) == 12 and offsetOf(TimePage, base) == 16
  assert offsetOf(TimePage, hz) == 24 and offsetOf(TimePage, mul) == 32
  assert offsetOf(TimePage, shift) == 36
  var m: array[8, char]
  var magic = TimePageMagic
  copyMem(addr m[0], addr magic, 8)
  assert $m[0] & $m[1] & $m[2] & $m[3] & $m[4] & $m[5] & $m[6] & $m[7] == "NIMIXTIM"
  assert TimePageAddr == 224'u64 * 1024 * 1024, "right after the 96 MB + 128 MB arena"

  # What the kernel publishes is what an app computes, for every frequency.
  for hz in Freqs:
    let k = newTscClock(0x1_0000_0000'u64, hz)
    let page = toTimePage(k)
    for tsc in [0'u64, 0x1_0000_0000'u64, 0x1_0000_0001'u64, 0x1_0000_0000'u64 + hz,
                0x1_0000_0000'u64 + 3600 * hz, 0xFFFF_FFFF_FFFF'u64]:
      let r = pageNanos(page, tsc)
      assert r.ok, "valid page reads ok"
      assert r.ns == clockNanos(k, tsc), "app reader == kernel reader"

  # Anything unrecognised is refused, so apps take the coarse fallback.
  let good = toTimePage(newTscClock(0, 2_000_000_000'u64))
  assert pageNanos(good, 1000).ok
  var bad = good
  bad.magic = 0
  assert not pageNanos(bad, 1000).ok, "wrong magic (page not published)"
  bad = good; bad.version = 2
  assert not pageNanos(bad, 1000).ok, "unknown version"
  bad = good; bad.valid = 0
  assert not pageNanos(bad, 1000).ok, "not calibrated"
  bad = good; bad.shift = 0
  assert not pageNanos(bad, 1000).ok, "shift 0"
  bad = good; bad.shift = 33
  assert not pageNanos(bad, 1000).ok, "shift 33"
  bad = good; bad.mul = 0
  assert not pageNanos(bad, 1000).ok, "mul 0"
  assert not pageNanos(toTimePage(newTscClock(0, 0)), 1000).ok, "invalid clock publishes invalid"
  var zero: TimePage
  assert not pageNanos(zero, 1000).ok, "an all-zero (unmapped-looking) page is invalid"
  echo "PASS: time page layout, app reader == kernel reader, bad pages refused"

proc testGoldenVectors() =
  ## The same file the C reader (libnimix/nimix_timepage.h) is tested against:
  ## regenerate with tests/libnimix/gen_clock_vectors.nim if the algorithm is
  ## changed on purpose, and the C test then holds the other side to it.
  const Vectors = staticRead("libnimix/clock_vectors.txt")
  var n = 0
  for line in Vectors.splitLines:
    if line.len == 0 or line[0] == '#': continue
    let f = line.splitWhitespace
    assert f.len == 6, "vector line: " & line
    let c = TscClock(base: parseUInt(f[1]), mul: uint32(parseUInt(f[2])),
                     shift: uint8(parseUInt(f[3])), hz: parseUInt(f[0]), valid: true)
    assert clockNanos(c, parseUInt(f[4])) == parseUInt(f[5]), "golden vector: " & line
    assert newTscClock(c.base, c.hz).mul == c.mul and newTscClock(c.base, c.hz).shift == c.shift,
      "mul/shift for " & f[0]
    inc n
  assert n >= 60, "vectors present"
  echo "PASS: ", n, " golden vectors shared with the C reader"

when isMainModule:
  testMultiplierFits()
  testRejectsImplausible()
  testAccuracyAcrossSpans()
  testMonotonicAndClamped()
  testTscWrapsHighHalf()
  testCalibrationWindow()
  testMeasurementGuards()
  testMedianOf()
  testTimePage()
  testGoldenVectors()
  echo "All TSC clock tests passed."
