# SPDX-License-Identifier: GPL-2.0
## Tests for the event server — pure logic, no hardware

import ../kernel/event_server
import ../kernel/traits/event

proc testSubscribePublishPoll() =
  eventServerInit()

  let tok = eventSubscribe("test.ping")
  assert tok.isValid, "subscribe returns valid token"
  assert eventPoll(tok).isNone, "nothing published yet"

  eventPublish("test.ping", "hello", 5)

  let ev = eventPoll(tok)
  assert ev.isSome, "event available after publish"
  echo "PASS: subscribe/publish/poll"

proc testFanOut() =
  eventServerInit()
  let t1 = eventSubscribe("sys.tick")
  let t2 = eventSubscribe("sys.tick")

  eventPublish("sys.tick", "1", 1)

  assert eventPoll(t1).isSome, "t1 receives fan-out event"
  assert eventPoll(t2).isSome, "t2 receives fan-out event"
  echo "PASS: fan-out to multiple subscribers"

proc testTopicFiltering() =
  eventServerInit()
  let tok = eventSubscribe("test.other")
  eventPublish("test.ping", "x", 1)
  assert eventPoll(tok).isNone, "different topic gets nothing"
  echo "PASS: topic filtering"

proc testRingBufferFull() =
  eventServerInit()
  let tok = eventSubscribe("flood.test")
  # Fill the per-token ring buffer (MaxPendingPerToken = 16)
  for i in 0..<20:
    eventPublish("flood.test", "x", 1)
  # We should get exactly MaxPendingPerToken events (extras dropped)
  var count = 0
  while eventPoll(tok).isSome:
    inc count
  assert count == MaxPendingPerToken, "ring buffer capped at MaxPendingPerToken"
  echo "PASS: ring buffer cap (dropped extras)"

proc testInvalidToken() =
  eventServerInit()
  let badTok = EventToken(0)
  assert not badTok.isValid, "zero token is invalid"
  assert eventPoll(badTok).isNone, "poll on invalid token returns none"
  echo "PASS: invalid token handling"

when isMainModule:
  testSubscribePublishPoll()
  testFanOut()
  testTopicFiltering()
  testRingBufferFull()
  testInvalidToken()
  echo "All event server tests passed."
