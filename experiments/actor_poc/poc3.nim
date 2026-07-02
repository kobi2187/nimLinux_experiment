# POC3: canonical cps idiom from the cps tutorial.
# Magic queues the continuation + returns nil (pause). A scheduler pops and
# resumes by stepping c.fn(c) — NOT trampoline (which runs to completion).
import cps
import std/deques

type
  Msg = object
    v: int
  Co = ref object of Continuation
    sched: Sched
    inbox: Deque[Msg]
    pending: Msg
  Sched = ref object
    ready: Deque[Co]      # continuations ready to run

proc self(c: Co): Co {.cpsVoodoo.} = c

proc receive(c: Co): Co {.cpsMagic.} =
  ## If a message is waiting, take it and continue. Else pause: the scheduler
  ## will re-queue this continuation when a message is delivered.
  if c.inbox.len > 0:
    c.pending = c.inbox.popFirst()
    return c              # continue this leg
  # park: do NOT re-queue here; delivery re-queues us. Return nil to pause.
  return nil

proc body() {.cps: Co.} =
  receive()
  echo "got ", self().pending.v
  receive()
  echo "got ", self().pending.v

# Deliver a message and mark the actor runnable.
proc deliver(s: Sched; c: Co; m: Msg) =
  c.inbox.addLast m
  s.ready.addLast c

# Scheduler: run each ready continuation one leg at a time until it pauses.
proc run(s: Sched) =
  while s.ready.len > 0:
    var c: Continuation = s.ready.popFirst()
    while c != nil and c.running:
      c = c.fn(c)
    # c paused (fn returned nil) or finished; delivery re-queues when a msg lands.

proc main() =
  let s = Sched(ready: initDeque[Co]())
  var c = Co(whelp body())
  c.sched = s
  c.inbox = initDeque[Msg]()
  s.ready.addLast c
  s.run()                       # runs to first receive → pauses (empty inbox)
  deliver(s, c, Msg(v: 42))
  s.run()                       # resumes: got 42, pauses at 2nd receive
  deliver(s, c, Msg(v: 99))
  s.run()                       # resumes: got 99, completes
  echo "PASS"

main()
