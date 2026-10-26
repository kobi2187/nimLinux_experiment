# SPDX-License-Identifier: GPL-2.0
## Frame-pointer backtrace for fatal reports on serial.
##
## The kernel builds with -fno-omit-frame-pointer, so every frame starts with
## [saved rbp][return address]. Output lines have the form
##     "  #<n> 0x<addr>"
## which tools/symbolize.py turns into function names on the host.

import ./serial

const MaxFrames* = 24

const CanonicalLowEnd* = 0x0000_8000_0000_0000'u64

proc frameStep*(frame: uint64; lo = 0'u64; hi = CanonicalLowEnd): tuple[ok: bool; next, ret: uint64] =
  ## One unwind step with sanity checks. A frame must be 8-aligned, non-null
  ## and lie in [lo, hi - 16) — for a user task, its own region: a corrupt user
  ## rbp must never make the kernel fault while reporting the crash.
  if frame == 0 or (frame and 7) != 0 or frame < lo or frame + 16 > hi:
    return (false, 0'u64, 0'u64)
  let next = cast[ptr uint64](frame)[]
  let ret  = cast[ptr uint64](frame + 8)[]
  (true, next, ret)

proc printBacktrace*(rip, rbp: uint64; lo = 0'u64; hi = CanonicalLowEnd) =
  ## rip = 0: called from a panic (no faulting instruction) — frames only.
  defaultSerial.putString("backtrace:\n")
  if rip != 0:
    defaultSerial.putString("  #0 0x")
    defaultSerial.putHex(rip)
    defaultSerial.putChar('\n')
  var frame = rbp
  var n = 1
  while n < MaxFrames:
    let s = frameStep(frame, lo, hi)
    if not s.ok or s.ret == 0: break
    defaultSerial.putString("  #")
    defaultSerial.putInt(int64(n))
    defaultSerial.putString(" 0x")
    defaultSerial.putHex(s.ret)
    defaultSerial.putChar('\n')
    if s.next <= frame or s.next - frame > 0x10_0000'u64: break   # 1 MiB
    frame = s.next
    inc n

proc currentRbp*(): uint64 {.inline.} =
  {.emit: "asm volatile(\"mov %%rbp, %0\" : \"=r\"(`result`));".}

proc nimixPrintBacktraceHere*() {.exportc, noinline.} =
  ## Backtrace of the caller's stack (used by rtl_stubs.c exit/abort).
  printBacktrace(0'u64, currentRbp())
