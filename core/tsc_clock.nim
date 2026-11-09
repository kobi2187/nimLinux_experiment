# SPDX-License-Identifier: GPL-2.0
## TSC clock — pure fixed-point math for a fine monotonic clock.
##
## ns = ((tsc - base) * mul) >> shift     (Linux clocksource mult/shift)
##
## No hardware here: this module is host-tested (tests/test_tsc_clock.nim) and
## shared by the kernel driver (drivers/tsc.nim) and, later, by apps reading a
## read-only time page without a syscall (VISION budget: ~1 kernel call per
## frame, and raylib's GetTime() runs every frame).
##
## The 64x32 -> 96-bit product is done as two 32-bit halves, so there is no
## 128-bit type; the result is exact for any tsc delta while the answer fits in
## 64 bits (584 years of nanoseconds).

const
  NsPerSec*   = 1_000_000_000'u64
  PitHz*      = 1_193_182'u64     ## PIT oscillator, for the calibration window
  MinTscHz*   = 1_000_000'u64     ## below this the measurement is rejected
  MaxTscHz*   = 100_000_000_000'u64

type
  TscClock* = object
    base*: uint64     ## TSC value at nanosecond zero
    mul*: uint32
    shift*: uint8
    hz*: uint64       ## calibrated TSC frequency (informational)
    valid*: bool

proc pitWindowNanos*(counts: uint16): uint64 =
  ## How long a PIT channel-2 one-shot of `counts` ticks lasts.
  (uint64(counts) * NsPerSec) div PitHz

proc measuredHz*(deltaTsc, deltaNs: uint64): uint64 =
  ## TSC frequency from one calibration window; 0 if the numbers can't be
  ## trusted (window empty, or long enough that the product would overflow).
  if deltaNs == 0 or deltaTsc == 0 or deltaTsc > 18_000_000_000'u64: return 0
  let hz = (deltaTsc * NsPerSec) div deltaNs
  if hz < MinTscHz or hz > MaxTscHz: 0'u64 else: hz

proc medianOf*(samples: openArray[uint64]): uint64 =
  ## The middle sample (the upper middle for an even count; 0 for none), so one
  ## disturbed window can't skew the result. Insertion sort of at most 15 values.
  const Max = 15
  let n = min(samples.len, Max)
  if n == 0: return 0
  var a: array[Max, uint64]
  for i in 0 ..< n:
    let v = samples[i]
    var j = i
    while j > 0 and a[j - 1] > v:
      a[j] = a[j - 1]
      dec j
    a[j] = v
  a[n div 2]

proc newTscClock*(base, hz: uint64): TscClock =
  ## Build a clock from the TSC value taken at "now" and its frequency.
  ## `valid` is false for an implausible frequency.
  result.base = base
  result.hz = hz
  if hz < MinTscHz or hz > MaxTscHz: return
  # Largest shift whose multiplier still fits in 32 bits (most precision).
  var shift = 32'u8
  while shift > 1:
    let m = ((NsPerSec shl shift) + hz div 2) div hz     # rounded, not floored
    if m < (1'u64 shl 32):
      result.mul = uint32(m)
      result.shift = shift
      result.valid = true
      return
    dec shift

proc clockNanos*(c: TscClock; tsc: uint64): uint64 {.inline.} =
  ## Nanoseconds since `base`. Before `base` (or an invalid clock) it is 0, so
  ## readers never see time run backwards.
  if not c.valid or tsc <= c.base: return 0
  let d = tsc - c.base
  let hi = (d shr 32) * uint64(c.mul)                  # < 2^64: both < 2^32
  let lo = (d and 0xFFFF_FFFF'u64) * uint64(c.mul)
  # ((hi << 32) + lo) >> shift with shift <= 32; hi << 32 is a multiple of
  # 2^shift, so splitting the shift loses nothing.
  (hi shl (32'u8 - c.shift)) + (lo shr c.shift)

# ── The time page: the clock, published to apps (V3b) ─────────────────────────
#
# The kernel writes this once at boot, before any task runs, into its own 2 MB
# window at TimePageAddr (right after the buffer arena) and maps it USER
# READ-ONLY for every task. An app reads it and applies `clockNanos` to its own
# rdtsc: no syscall, no kernel entry, no lock (the page never changes after
# boot; if recalibration is ever added, add a sequence counter first).
# A user write to it faults and kills only that task.
#
# This is the same "sealed" idea as the buffers model (immutable data may be
# shared; mutable data may not), done as a fixed page because every task needs
# it and the address must not depend on a handle.

const
  TimePageAddr*    = 0xE000000'u64          ## 224 MB = ArenaBase + ArenaSize
  TimePageMagic*   = 0x4D495458494D494E'u64 ## "NIMIXTIM", little-endian
  TimePageVersion* = 1'u32

type
  TimePage* {.packed.} = object
    magic*: uint64
    version*: uint32
    valid*: uint32      ## 1: the TSC fields below are usable
    base*: uint64
    hz*: uint64
    mul*: uint32
    shift*: uint32

static: doAssert sizeof(TimePage) == 40, "TimePage is ABI: 40 bytes"

proc toTimePage*(c: TscClock): TimePage =
  TimePage(magic: TimePageMagic, version: TimePageVersion,
           valid: (if c.valid: 1'u32 else: 0'u32),
           base: c.base, hz: c.hz, mul: c.mul, shift: uint32(c.shift))

proc pageClock*(p: TimePage): TscClock =
  ## The clock a page describes; `valid` is false for anything we don't
  ## recognise (wrong magic or version, not calibrated, shift out of range).
  result.base = p.base
  result.hz = p.hz
  result.mul = p.mul
  result.shift = uint8(p.shift and 0xFF)
  result.valid = p.magic == TimePageMagic and p.version == TimePageVersion and
                 p.valid == 1 and p.shift >= 1 and p.shift <= 32 and p.mul != 0

proc pageNanos*(p: TimePage; tsc: uint64): tuple[ok: bool, ns: uint64] {.inline.} =
  ## What an app computes: ok=false means "use the coarse fallback".
  let c = pageClock(p)
  (c.valid, clockNanos(c, tsc))
