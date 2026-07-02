# POC7: mirror examples/iterator.nim EXACTLY, adapted to a server loop.
# Body is `while true: receive()` (like a real server). Driver = produce-style
# trampolineIt that breaks when a message was consumed. Repeated drives on same a.
import cps
import std/deques

type
  Actor = ref object of Continuation
    inbox: Deque[int]
    got: bool           # analog of iterator's val.isSome
    last: int

proc self(c: Actor): Actor {.cpsVoodoo.} = c

proc receive(c: Actor): Actor {.cpsMagic.} =
  ## Take one message (scheduler guarantees non-empty), mark got, return c.
  c.last = c.inbox.popFirst()
  c.got = true
  return c

# server loop: receive forever, handling each message.
proc server() {.cps: Actor.} =
  while true:
    receive()
    echo "handled ", self().last

# produce-style driver: run until a message is consumed (got) or dismissed.
proc pump(a: sink Actor): Actor =
  trampolineIt a:
    if (Actor it).got:
      break
  result = a

proc main() =
  var a = Actor(whelp server())
  for v in [42, 99, 7]:
    a.inbox.addLast v
    a.got = false
    a = pump(a)
    doAssert not a.dismissed, "actor dismissed unexpectedly"
  echo "PASS: server loop consumed 3 messages"

main()
