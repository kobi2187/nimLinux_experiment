# SPDX-License-Identifier: GPL-2.0
## Actor idiomatic-suspend test. MUST compile --mm:arc --panics:on.
## Pattern: body = while true: suspend(); handle(recv()). Sender plants + resumes.
import ipc/mailbox
import runtime/actor
import cps

var log: seq[int]

proc mkMsg(b: byte): MailMsg =
  result.len = 1; result.data[0] = b

# Server-loop actor: park, then handle the planted message, forever.
proc worker() {.cps: Actor.} =
  while true:
    suspend()
    log.add(int(recv().data[0]))

proc testActorSuspendDeliver() =
  var a = Actor(whelp worker())
  resume(a)                          # run to first suspend
  assert a.isSuspended, "actor should be parked after first suspend"
  assert log.len == 0, "no message delivered yet"

  a.deliver(mkMsg(42))
  assert log == @[42], "first message handled"
  assert a.isSuspended, "re-armed after handling"

  a.deliver(mkMsg(99))
  assert log == @[42, 99], "second message handled, no duplicate"

  a.deliver(mkMsg(7))
  a.deliver(mkMsg(8))
  assert log == @[42, 99, 7, 8], "sequential deliveries, in order, no loss"
  echo "PASS: idiomatic actor suspend/deliver"

testActorSuspendDeliver()
echo "All actor tests passed."
