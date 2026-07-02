# POC6: scheduler owns readiness. An actor is only driven when its inbox is
# non-empty, so receive() always finds a message. receive sets a "yielded" flag
# and returns c; the driver breaks after each receive leg (one message per leg).
# This is the iterator jield pattern: pause AFTER consuming, one item per drive.
import cps
import std/deques

type
  Msg = object
    v: int
  Actor = ref object of Continuation
    inbox: Deque[Msg]
    pending: Msg
    yielded: bool        # set by receive after taking a msg; driver breaks on it
    done: bool

proc self(c: Actor): Actor {.cpsVoodoo.} = c

proc receive(c: Actor): Actor {.cpsMagic.} =
  ## Precondition (scheduler-enforced): inbox non-empty. Take one message and
  ## mark yielded so the driver pauses this leg. Always returns c (alive).
  assert c.inbox.len > 0, "receive driven with empty inbox"
  c.pending = c.inbox.popFirst()
  c.yielded = true
  return c

proc body() {.cps: Actor.} =
  receive()
  echo "got ", self().pending.v
  receive()
  echo "got ", self().pending.v

# Drive one leg: run until receive yields (one message consumed) or the actor
# finishes. Clear yielded first so the break fires on THIS leg's receive.
proc driveOne(a: sink Actor): Actor =
  a.yielded = false
  trampolineIt a:
    if (Actor it).yielded:
      break
  result = a

# Scheduler: only drive when the inbox has something.
proc feed(a: sink Actor; m: Msg): Actor =
  a.inbox.addLast m
  if not a.finished:
    result = driveOne(a)
  else:
    result = a

proc main() =
  var a = Actor(whelp body())
  a = feed(a, Msg(v: 42))       # inbox has 42 → drive → receive pops 42, echoes
  doAssert not a.finished
  a = feed(a, Msg(v: 99))       # drive → pops 99, echoes, completes
  doAssert a.finished, "should have finished after 2 messages"
  echo "PASS: scheduler-gated blocking receive"

main()
