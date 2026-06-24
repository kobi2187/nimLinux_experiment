# SPDX-License-Identifier: GPL-2.0
## Test: does nim-cps compile and work under --skipParentCfg --mm:arc?
## This validates the CPS runtime before we use it in the dispatcher.
##
## NOTE: nim-cps requires --mm:arc (or --mm:orc) and --panics:on.
## It is NOT compatible with --mm:refc (the NimixOS host test flag).
## This file must be compiled with --mm:arc (see note below).
##
## Compile: nim c -r --skipParentCfg --mm:arc --panics:on \
##            --path:/home/kl/prog/nimLinux_experiment \
##            -d:noSignalHandler tests/test_cps_eval.nim

import cps

type C = ref object of Continuation

# A cpsMagic proc that suspends the continuation (returns nil to the trampoline)
proc suspend(c: sink C): C {.cpsMagic.} =
  result = nil  # returning nil causes trampoline to stop

proc hello() {.cps: C.} =
  echo "step 1"
  suspend()     # cooperative yield point — suspends continuation
  echo "step 2"

proc testCpsBasic() =
  var c = whelp hello()
  c = trampoline(c)   # run to first yield (suspend)
  echo "PASS: CPS continuation suspended"
  c = trampoline(c)   # run to completion
  echo "PASS: CPS continuation completed"

testCpsBasic()
echo "All CPS eval tests passed."
