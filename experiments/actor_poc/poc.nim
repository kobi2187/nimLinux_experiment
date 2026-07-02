# Minimal cps POC: can a continuation parked by a nil-returning magic be
# resumed later (held externally), and is state mutated in the magic visible
# to the body afterward via a voodoo accessor?
import cps

type Co = ref object of Continuation
  value*: int
  parked*: bool

var gHeld: Co    # external holder (stands in for the scheduler)

proc self(c: Co): Co {.cpsVoodoo.} = c

proc pause(c: Co): Co {.cpsMagic.} =
  ## Always park the first time: stash externally, return nil to stop trampoline.
  if not c.parked:
    c.parked = true
    gHeld = c
    return nil
  # second entry: continue
  c

proc body() {.cps: Co.} =
  echo "before pause, value=", self().value
  pause()
  echo "after pause, value=", self().value

proc main() =
  var c = Co(whelp body())
  c.value = 10
  gHeld = nil
  discard trampoline(c)          # runs to pause → parks
  echo "parked? ", gHeld != nil
  doAssert gHeld != nil, "should have parked into gHeld"
  # mutate state on the held continuation, then resume it
  gHeld.value = 20
  gHeld.parked = true            # so pause() takes the continue path
  discard trampoline(gHeld)      # resume past pause
  echo "PASS"

main()
