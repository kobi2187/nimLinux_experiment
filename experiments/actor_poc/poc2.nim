# POC2: mirror the real `receive` — magic re-checks a queue on resume and pops.
# No separate parked flag; the magic itself decides park-vs-continue by queue state.
import cps

type
  Msg = object
    v: int
  Co = ref object of Continuation
    queue: seq[Msg]     # stands in for the mailbox
    pending: Msg

var gHeld: Co

proc self(c: Co): Co {.cpsVoodoo.} = c

proc receive(c: Co): Co {.cpsMagic.} =
  ## Pop if available (continue); else park (stash + nil).
  if c.queue.len > 0:
    c.pending = c.queue[0]
    c.queue.delete(0)
    return c
  gHeld = c
  return nil

proc body() {.cps: Co.} =
  receive()
  echo "got ", self().pending.v
  receive()
  echo "got ", self().pending.v

var log: seq[int]
proc main() =
  var c = Co(whelp body())
  gHeld = nil
  discard trampoline(c)              # first receive → empty → parks
  doAssert gHeld != nil, "parked 1"
  var held = gHeld; gHeld = nil
  held.queue.add(Msg(v: 42))         # deliver
  discard trampoline(held)           # resume: pops 42, echoes, next receive parks
  doAssert gHeld != nil, "parked 2"
  held = gHeld; gHeld = nil
  held.queue.add(Msg(v: 99))
  discard trampoline(held)           # resume: pops 99, echoes, completes
  doAssert gHeld == nil, "should have completed, not parked"
  echo "PASS: two-message receive loop"

main()
