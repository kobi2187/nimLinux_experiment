# SPDX-License-Identifier: GPL-2.0
## Actor receive-loop + scheduler test. MUST compile --mm:arc --panics:on.
## Proven idiom: body is `while true: receive()`; scheduler pumps when inbox ready.
import ipc/mailbox
import runtime/actor
import runtime/actor_scheduler
import cps

var log: seq[int]

proc mkMsg(b: byte): MailMsg =
  result.len = 1; result.data[0] = b

# Server-loop actor: receive forever, logging each message's first payload byte.
# Scheduler only pumps when the inbox has a message, so receive always delivers.
proc worker() {.cps: Actor.} =
  while true:
    receive()
    log.add(int(self().pending.data[0]))

proc testActorLoopThroughScheduler() =
  var s: ActorSched
  schedInit(s)
  let inbox = newInbox()
  var a = Actor(whelp worker())
  a.inbox = inbox
  schedAdd(s, a)

  # Empty inbox: runOnce pumps nothing.
  runOnce(s)
  assert log.len == 0, "no message → no processing"

  discard post(inbox, mkMsg(42))
  runOnce(s)
  assert log == @[42], "first message handled"

  discard post(inbox, mkMsg(99))
  runOnce(s)
  assert log == @[42, 99], "second message handled"

  # Two messages, two passes drain both.
  discard post(inbox, mkMsg(7))
  discard post(inbox, mkMsg(8))
  runOnce(s)
  runOnce(s)
  assert log == @[42, 99, 7, 8], "queued messages drained over passes"
  echo "PASS: actor receive-loop through scheduler"

testActorLoopThroughScheduler()
echo "All actor tests passed."
