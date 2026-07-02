# poc11: iterator-exact pattern. jield-style: receive sets pending+has, returns c.
# Driver reads pending, CLEARS has (like iterator's val=none). Handler guarded on
# has so a re-run leg with cleared pending is a no-op. One msg per pump.
import cps
import std/deques
type Actor = ref object of Continuation
  inbox: Deque[int]
  pending: int
  has: bool          # analog of Option.isSome
proc self(c: Actor): Actor {.cpsVoodoo.} = c
proc receive(c: Actor): Actor {.cpsMagic.} =
  # like jield: publish next value, return c. Driver consumes + clears has.
  if c.inbox.len > 0:
    c.pending = c.inbox.popFirst()
    c.has = true
  return c
var log: seq[int]
proc worker() {.cps: Actor.} =
  while true:
    receive()
    if self().has:                 # guard: only handle a fresh value
      log.add(self().pending)
proc pump(a: sink Actor): Actor =
  # run until receive publishes a value (has), like iterator's produce breaking on isSome
  trampolineIt a:
    if (Actor it).has:
      break
  result = a
proc main() =
  var a = Actor(whelp worker())
  for v in [42, 99, 7]:
    a.inbox.addLast v
    a = pump(a)
    echo "after ", v, ": log=", log, " has=", a.has
    a.has = false                  # consume: clear so the handler re-run is a no-op
  echo "final log=", log
main()
