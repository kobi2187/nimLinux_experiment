# SPDX-License-Identifier: GPL-2.0
## Structured test output protocol — machine-readable serial lines.
##
## Output format (one line per event, parsed by qemu_harness.py):
##   TEST PASS: <name>
##   TEST FAIL: <name> reason=<reason>
##   TEST DONE: <passed>/<total> suite=<suite>
##
## Works in two contexts selected at compile time:
##   default (no flag)      — kernel ring-0, writes via core/serial
##   -d:nimixUserspace      — ring-3 app, writes via nimixWrite ABI call

when defined(nimixUserspace):
  proc nimixWrite(buf: pointer; len: int) {.importc, cdecl.}

  proc serialLine(s: string) =
    if s.len > 0:
      nimixWrite(unsafeAddr s[0], s.len)
    let nl = "\n"
    nimixWrite(unsafeAddr nl[0], 1)
else:
  import ../core/serial
  proc serialLine(s: string) = kprintln(s)

# ── State ─────────────────────────────────────────────────────────────────────

var
  tpSuite*:  string
  tpPassed*: int
  tpTotal*:  int

# ── API ───────────────────────────────────────────────────────────────────────

proc testSuiteStart*(name: string) =
  tpSuite  = name
  tpPassed = 0
  tpTotal  = 0

proc testPass*(name: string) =
  inc tpTotal
  inc tpPassed
  serialLine("TEST PASS: " & name)

proc testFail*(name: string; reason: string) =
  inc tpTotal
  serialLine("TEST FAIL: " & name & " reason=" & reason)

proc testDone*() =
  serialLine("TEST DONE: " & $tpPassed & "/" & $tpTotal & " suite=" & tpSuite)

template check*(name: string; cond: bool) =
  if cond: testPass(name) else: testFail(name, "assertion false")

template checkEq*[T](name: string; a, b: T) =
  if a == b: testPass(name) else: testFail(name, "got " & $a & " want " & $b)
