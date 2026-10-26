# SPDX-License-Identifier: GPL-2.0
## Panic override for the freestanding (--os:any) kernel.
##
## Nim's runtime calls these two hooks when a check fails (IndexDefect, bounds,
## nil-deref, overflow, failed assert) or an unhandled exception escapes. Without
## this module such a failure faults silently — which is why the kernel previously
## had to build with -d:danger. With checks ON, this routes the defect message to
## the serial console and halts, so real errors are observable.

import ../../core/serial
import ../../core/backtrace

proc rawoutput*(s: string) =
  ## Nim runtime sink for defect/exception text.
  kprint(s)

proc panic*(s: string) {.noreturn.} =
  ## Final stop after a runtime check failure. Print, then halt forever.
  kprintln("")
  kprintln("=== KERNEL PANIC (runtime check) ===")
  kprintln(s)
  printBacktrace(0'u64, currentRbp())
  kprintln("=== halted (symbolize: tools/symbolize.py <serial log>) ===")
  while true:
    asm """ cli; hlt """
