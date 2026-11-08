# SPDX-License-Identifier: GPL-2.0
## TSC clock driver — a fine monotonic clock for the whole OS.
##
## The PIT stays the scheduler tick (100 Hz). This calibrates the timestamp
## counter against PIT channel 2 (a one-shot of ~30 ms, polled through port
## 0x61 bit 5, the way Linux's pit_calibrate_tsc does), five times, and keeps
## the median: host scheduling jitter (QEMU) or an IRQ lands in one window at
## a time and the median discards it. After that,
## `tscNanos()` is a single rdtsc plus two multiplies: no port I/O, no syscall.
##
## The maths is core/tsc_clock.nim (host-tested). This file is only the
## hardware: ports, rdtsc, and the global the kernel reads.
##
## Assumes an invariant TSC, which holds for the QEMU target (TCG derives the
## TSC from the virtual clock, and so does the PIT). A real-hardware port
## would check CPUID 0x80000007 and fall back to the PIT.

import ../core/tsc_clock

var gClock: TscClock

proc tscClock*(): TscClock {.inline.} = gClock
  ## The calibrated clock, by value: what a read-only time page publishes to apps.

proc tscReady*(): bool {.inline.} = gClock.valid

when not defined(noKernelHardware):
  import ../arch/x86_64/cpu_primitives
  import ../core/log

  const
    Pit2Data   = 0x42'u16
    PitCmdPort = 0x43'u16
    Port61     = 0x61'u16     ## bit0 gate2, bit1 speaker, bit5 OUT2 (read)
    WindowCounts = 35795'u16  ## ~30 ms of PIT time
    Windows    = 5
    MaxSpins   = 50_000_000   ## poll bound: never hang boot on a dead PIT

  proc measureWindow(): uint64 =
    ## TSC cycles that elapse during one PIT channel-2 window; 0 on timeout.
    let saved = inb(Port61)
    outb(Port61, (saved and 0xFC'u8) or 0x01'u8)   # gate on, speaker off
    outb(PitCmdPort, 0xB0'u8)                      # ch2, lo/hi, mode 0, binary
    outb(Pit2Data, uint8(WindowCounts and 0xFF))
    let t0 = rdtsc()                               # counting starts as the high byte lands
    outb(Pit2Data, uint8(WindowCounts shr 8))
    let t1 = block:
      var spins = 0
      while (inb(Port61) and 0x20'u8) == 0:        # OUT2 goes high at terminal count
        inc spins
        if spins > MaxSpins:
          outb(Port61, saved)
          return 0
      rdtsc()
    outb(Port61, saved)
    t1 - t0

  proc tscInit*() =
    ## Calibrate and publish the clock. Call once at boot, interrupts off
    ## (an IRQ in a window would only inflate it, and the median discards that,
    ## but there is no reason to invite one).
    let windowNs = pitWindowNanos(WindowCounts)
    var hz: array[Windows, uint64]
    for i in 0 ..< Windows:
      hz[i] = measuredHz(measureWindow(), windowNs)
      if hz[i] == 0:
        klog(llError, "[TSC] calibration window failed; clock not available")
        return
    let f = medianOf(hz)
    gClock = newTscClock(rdtsc(), f)
    if gClock.valid:
      klogInt(llInfo, "[TSC] ✓ calibrated, MHz: ", int64(f div 1_000_000))
      var lo = hz[0]
      var hi = hz[0]
      for v in hz:
        lo = min(lo, v)
        hi = max(hi, v)
      klogInt(llInfo, "[TSC]   spread across windows, kHz: ", int64((hi - lo) div 1000))
    else:
      klog(llError, "[TSC] implausible frequency; clock not available")

  proc tscNanos*(): uint64 {.inline.} =
    ## Nanoseconds since tscInit(). Monotonic; 0 until calibrated.
    clockNanos(gClock, rdtsc())
