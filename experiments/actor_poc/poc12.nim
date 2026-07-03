# poc12: THE idiomatic cps pattern from examples/coroutine.nim.
# suspend() just parks (stores self). send() plants data + resumes. recv() reads
# after suspend returns. NO flags, NO counters. Trace every state var per step.
import cps
type Actor = ref object of Continuation
  data: int
  suspended: Actor

template resume(c: Actor): untyped = discard trampoline c
proc recv(c: Actor): int {.cpsVoodoo.} = c.data
proc suspend(c: Actor): Actor {.cpsMagic.} =
  c.suspended = c
  c.suspended

var log: seq[int]
proc consumer() {.cps: Actor.} =
  while true:
    suspend()
    let v = recv()
    log.add(v)
    echo "  [body] handled ", v, " log=", log

proc send(c: Actor; n: int) =
  echo "send ", n, ": suspended=", (c.suspended != nil)
  c.data = n
  resume c.suspended

proc main() =
  let a = Actor(whelp consumer())
  echo "whelped: suspended=", (a.suspended != nil)
  resume a                       # run to first suspend
  echo "after first resume: suspended=", (a.suspended != nil), " data=", a.data
  for i in [42, 99, 7]:
    send(a, i)
    echo "after send ", i, ": log=", log
  reset a.suspended
  echo "final log=", log

main()
