# POC5: the real idiom — trampolineIt + break, magic returns c (never nil).
# receive() marks "want a message" and returns c; the driver runs legs until the
# actor is waiting, then breaks. Delivery + re-drive resumes it. Single owner: `a`.
import cps
import std/deques

type
  Msg = object
    v: int
  Actor = ref object of Continuation
    inbox: Deque[Msg]
    pending: Msg
    waiting: bool        # true while blocked in receive with empty inbox

proc self(c: Actor): Actor {.cpsVoodoo.} = c

proc receive(c: Actor): Actor {.cpsMagic.} =
  ## Take a message if present (clear waiting, continue). Else set waiting and
  ## return c — the driver's trampolineIt breaks on `waiting`, pausing the body
  ## right here. On the next drive (after delivery), this leg re-runs and pops.
  if c.inbox.len > 0:
    c.pending = c.inbox.popFirst()
    c.waiting = false
    return c
  c.waiting = true
  return c

proc body() {.cps: Actor.} =
  receive()
  echo "got ", self().pending.v
  receive()
  echo "got ", self().pending.v

# Drive the actor until it blocks waiting (empty receive) or finishes.
# Clear `waiting` first so the break fires only when receive NEWLY sets it this
# drive — otherwise the stale flag breaks before the resumed leg can run.
proc drive(a: sink Actor): Actor =
  a.waiting = false
  trampolineIt a:
    if (Actor it).waiting:
      break
  result = a

proc main() =
  var a = Actor(whelp body())
  echo "id after whelp: ", cast[uint](a)
  a = drive(a)                 # runs to first receive → waiting=true, pauses
  echo "id after drive1: ", cast[uint](a), " waiting=", a.waiting, " inboxLen=", a.inbox.len
  doAssert a.waiting, "should be waiting after empty receive"
  a.inbox.addLast Msg(v: 42)
  echo "after addLast: inboxLen=", a.inbox.len
  a = drive(a)                 # re-runs receive: pops 42, echoes, blocks again
  echo "id after drive2: ", cast[uint](a), " waiting=", a.waiting
  doAssert a.waiting
  a.inbox.addLast Msg(v: 99)
  a = drive(a)                 # pops 99, echoes, completes
  doAssert a.finished, "should have finished"
  echo "PASS: blocking receive via trampolineIt"

main()
