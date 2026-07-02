# POC4: single-ownership. The scheduler owns the continuation at all times.
# receive() parks by moving `c` into a wait slot (owned there) and returning nil.
# deliver() moves it from the wait slot to the ready queue. No external handle.
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
    ready:  Deque[Co]
    waiting: Co          # single parked actor (POC scale)

proc self(c: Co): Co {.cpsVoodoo.} = c

proc receive(c: Co): Co {.cpsMagic.} =
  ## Message waiting → take it, continue. Else park: hand ownership to the
  ## scheduler's wait slot and return nil (pause this leg).
  if c.inbox.len > 0:
    c.pending = c.inbox.popFirst()
    return c
  c.sched.waiting = c          # scheduler now owns the parked continuation
  return nil

proc body() {.cps: Co.} =
  receive()
  echo "got ", self().pending.v
  receive()
  echo "got ", self().pending.v

proc run(s: Sched) =
  while s.ready.len > 0:
    var c: Continuation = s.ready.popFirst()
    while c != nil and c.running:
      c = c.fn(c)

proc deliver(s: Sched; m: Msg) =
  ## Deliver to the parked actor: move it from wait slot to ready.
  doAssert s.waiting != nil, "deliver: no waiting actor"
  let c = s.waiting
  s.waiting = nil
  c.inbox.addLast m
  s.ready.addLast c

proc main() =
  let s = Sched(ready: initDeque[Co]())
  var c = Co(whelp body())
  c.sched = s
  c.inbox = initDeque[Msg]()
  s.ready.addLast c            # hand to scheduler; do not keep a live handle
  s.run()                      # → first receive parks into s.waiting
  deliver(s, Msg(v: 42))
  s.run()                      # got 42, parks again
  deliver(s, Msg(v: 99))
  s.run()                      # got 99, completes
  echo "PASS"

main()
