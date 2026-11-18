# SPDX-License-Identifier: GPL-2.0
## Event Server — pub/sub backbone
##
## All inter-tier communication flows through here:
##   kernel → server notifications (device hotplug, tick events)
##   app → server via SIP channel (mediated by kernel)
##   server → server (direct subscription)
##
## In SASOS mode: direct in-process call, zero IPC overhead.
## In microkernel mode: this becomes a syscall into the kernel.
##
## No hardware dependencies — fully testable on the host.

import ./traits/event
import std/options

export options

type
  SubEntry = object
    active:  bool
    owner:   uint32   ## subscribing task's pid (0 = kernel / in-kernel WASM)
    topic:   array[MaxTopicLen, char]
    buf:     array[MaxPendingPerToken, Event]
    head:    int
    tail:    int
    count:   int
    seqNext: uint64

var
  subscriptions: array[MaxSubscribers, SubEntry]
  subCount:      int = 0

proc eventServerInit*() =
  ## Initialise (or reset) the event server. Idempotent — safe to call in tests.
  subCount = 0
  for i in 0..<MaxSubscribers:
    subscriptions[i].active = false
    subscriptions[i].count  = 0
    subscriptions[i].head   = 0
    subscriptions[i].tail   = 0

proc topicMatch(a, b: array[MaxTopicLen, char]): bool {.inline.} =
  for i in 0..<MaxTopicLen:
    if a[i] != b[i]: return false
    if a[i] == '\0': return true
  true

proc fillTopic(dst: var array[MaxTopicLen, char], src: cstring) =
  for i in 0..<MaxTopicLen:
    if src[i] == '\0' or i == MaxTopicLen - 1:
      dst[i] = '\0'
      break
    dst[i] = src[i]

proc eventSubscribe*(topic: cstring; owner: uint32 = 0): EventToken =
  ## Register interest in a topic. Returns an EventToken for polling.
  ## Returns EventToken(0) (invalid) if the subscriber table is full.
  ## Released slots are reused (they leaked before: 256 runs and done).
  var idx = -1
  for i in 0 ..< subCount:
    if not subscriptions[i].active:
      idx = i
      break
  if idx < 0:
    if subCount >= MaxSubscribers:
      return EventToken(0)
    idx = subCount
    inc subCount
  subscriptions[idx].owner   = owner
  subscriptions[idx].active  = true
  subscriptions[idx].count   = 0
  subscriptions[idx].head    = 0
  subscriptions[idx].tail    = 0
  subscriptions[idx].seqNext = 0
  fillTopic(subscriptions[idx].topic, topic)
  EventToken(uint32(idx + 1))  # 1-based; 0 = invalid

proc eventUnsubscribe*(token: EventToken) =
  ## Release one subscription; its slot is reused by later subscribers.
  let idx = int(uint32(token)) - 1
  if idx >= 0 and idx < subCount:
    subscriptions[idx].active = false
    subscriptions[idx].count  = 0

proc eventReleaseOwner*(owner: uint32) =
  ## Release every subscription held by a task that has exited or was killed.
  if owner == 0: return
  for i in 0 ..< subCount:
    if subscriptions[i].active and subscriptions[i].owner == owner:
      subscriptions[i].active = false
      subscriptions[i].count  = 0

proc eventPublish*(topic: cstring, data: pointer, dataLen: int) =
  ## Emit an event to all subscribers of `topic`.
  ## Subscribers whose ring buffer is full silently drop the event.
  var topicArr: array[MaxTopicLen, char]
  fillTopic(topicArr, topic)

  for i in 0..<subCount:
    if not subscriptions[i].active: continue
    if not topicMatch(subscriptions[i].topic, topicArr): continue

    var s = addr subscriptions[i]
    if s.count >= MaxPendingPerToken: continue  # drop — buffer full

    var ev: Event
    ev.topic  = topicArr
    ev.seqNum = s.seqNext
    inc s.seqNext

    let copyLen = min(dataLen, MaxPayloadLen)
    ev.payload.len = uint16(copyLen)
    if data != nil and copyLen > 0:
      let src = cast[ptr UncheckedArray[byte]](data)
      for j in 0..<copyLen:
        ev.payload.data[j] = src[j]

    s.buf[s.tail] = ev
    s.tail = (s.tail + 1) mod MaxPendingPerToken
    inc s.count

proc eventPublish*(topic: cstring, msg: cstring, msgLen: int) =
  ## Convenience overload for string literals in tests and kernel code.
  eventPublish(topic, cast[pointer](msg), msgLen)

proc eventPoll*(token: EventToken): Option[Event] =
  ## Non-blocking: return the next pending event for this token, or none().
  if not token.isValid: return none(Event)
  let idx = int(uint32(token)) - 1
  if idx < 0 or idx >= subCount: return none(Event)
  var s = addr subscriptions[idx]
  if s.count == 0: return none(Event)
  let ev = s.buf[s.head]
  s.head = (s.head + 1) mod MaxPendingPerToken
  dec s.count
  some(ev)
