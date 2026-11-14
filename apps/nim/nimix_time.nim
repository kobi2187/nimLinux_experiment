# SPDX-License-Identifier: GPL-2.0
## App-side clock (V3b): the kernel publishes a calibrated TSC clock in a
## read-only page (core/tsc_clock.nim: TimePage at TimePageAddr); this reads it
## with the app's own rdtsc. No syscall, no kernel entry: a clock read costs a
## few dozen cycles, which is what lets raylib's GetTime() run every frame
## inside VISION's budget of about one kernel call per frame.
##
## The page is mapped user read-only for every task; writing it faults and
## kills only the writer.
import ../../core/tsc_clock

proc nimixUptimeSecs(): uint64 {.importc, cdecl.}

proc rdtsc*(): uint64 {.inline.} =
  var lo, hi: uint32
  {.emit: ["asm volatile(\"rdtsc\" : \"=a\" (", lo, "), \"=d\" (", hi, "));"].}
  (uint64(hi) shl 32) or uint64(lo)

proc timePage*(): ptr TimePage {.inline.} = cast[ptr TimePage](TimePageAddr)

proc fineClock*(): bool =
  ## True when the kernel published a usable TSC clock.
  pageClock(timePage()[]).valid

proc nanoTime*(): uint64 =
  ## Monotonic nanoseconds since the kernel calibrated its clock. Falls back to
  ## whole seconds of uptime if the page isn't valid (the PIT was dead at boot;
  ## never the case on the QEMU target).
  let r = pageNanos(timePage()[], rdtsc())
  if r.ok: r.ns else: nimixUptimeSecs() * NsPerSec
