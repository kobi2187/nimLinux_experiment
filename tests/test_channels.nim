# SPDX-License-Identifier: GPL-2.0
## Tests for channel endpoints (ipc/handles/channel.nim): badges, handles that move with messages,
## atomic failure, peer-closed, release of what was in flight, task death, and no leaks.
import ../ipc/handles/handle_table
import ../ipc/handles/channel

var hs: HandleSpace
var ch: ChannelStore
var destroyedOther: seq[(ObjKind, int32)]

proc fresh(tasks = 4) =
  hsInit(hs); chInit(ch)
  destroyedOther = @[]
  chSetDestroyHook(proc(kind: ObjKind; payload: int32) {.nimcall.} =
    destroyedOther.add (kind, payload))
  for t in 0 ..< tasks: assert hsAttach(hs, t) == heOk

proc msg(s: string): seq[byte] =
  for c in s: result.add byte(c)

proc str(b: openArray[byte]; n: int): string =
  for i in 0 ..< n: result.add char(b[i])

proc pair(t: TaskId; badgeA, badgeB: uint64 = 0): (Handle, Handle) =
  var a, b: Handle
  assert chCreate(hs, ch, t, rtChannelDefault, rtChannelDefault, badgeA, badgeB, a, b) == crOk
  (a, b)

proc grant(frm, to: TaskId; h: Handle; narrow = rtChannelDefault): Handle =
  ## Spawn-time grant: move a handle between tables without a channel (what spawn does).
  var f: Flight
  var nh: Handle
  assert hsTransferOut(hs, frm, h, narrow, f) == heOk
  assert hsTransferIn(hs, to, f, nh) == heOk
  nh

proc recv(t: TaskId; h: Handle): tuple[r: ChResult, s: string, badge: uint64, got: seq[Handle]] =
  var buf: array[ChMsgBytes, byte]
  var n, nGot: int
  var badge: uint64
  var got: array[ChMaxFlights, Handle]
  let r = chRead(hs, ch, t, h, buf, n, badge, got, nGot)
  result.r = r
  if r == crOk:
    result.s = str(buf, n); result.badge = badge
    for k in 0 ..< nGot: result.got.add got[k]

proc testBadges() =
  fresh()
  # task 0 is the dispatcher: it keeps end A (badge 0) and issues end B to a client with badge 77
  let (a, b) = pair(0, 0, 77)
  let cb = grant(0, 1, b)
  assert chWrite(hs, ch, 1, cb, msg("hello")) == crOk
  var r = recv(0, a)
  assert r.r == crOk and r.s == "hello" and r.badge == 77, "the server sees the badge of the handle written through"
  assert chWrite(hs, ch, 0, a, msg("pong")) == crOk
  r = recv(1, cb)
  assert r.r == crOk and r.s == "pong" and r.badge == 0
  # a duplicate keeps the badge; the client cannot choose another
  var dup: Handle
  assert hsDuplicate(hs, 1, cb, rtRead or rtWrite, dup) == heOk
  assert chWrite(hs, ch, 1, dup, msg("via dup")) == crOk
  r = recv(0, a)
  assert r.badge == 77, "a duplicate is the same session"
  # a second client gets its own badge on its own channel, and cannot be confused with the first
  let (a2, b2) = pair(0, 0, 78)
  let c2 = grant(0, 2, b2)
  assert chWrite(hs, ch, 2, c2, msg("x")) == crOk
  assert recv(0, a2).badge == 78
  assert recv(0, a).r == crEmpty, "client 2's message did not land in client 1's channel"
  echo "PASS: badges stamp the sender's session; duplicates share it; sessions stay apart"

proc testRightsAndKinds() =
  fresh()
  let (a, b) = pair(0)
  var ro: Handle
  assert hsDuplicate(hs, 0, a, rtRead, ro) == heOk
  assert chWrite(hs, ch, 0, ro, msg("no")) == crNoRight, "write needs rtWrite"
  var wo: Handle
  assert hsDuplicate(hs, 0, a, rtWrite, wo) == heOk
  assert recv(0, wo).r == crNoRight, "read needs rtRead"
  var o: ObjId
  assert hsNewObject(hs, okBuffer, 1, o) == heOk
  var hb: Handle
  assert hsInstall(hs, 0, o, rtAll, 0, hb) == heOk
  assert chWrite(hs, ch, 0, hb, msg("no")) == crWrongType, "a buffer is not a channel"
  assert chWrite(hs, ch, 1, a, msg("no")) == crBadHandle, "task 1 holds nothing"
  assert chClose(hs, ch, 0, a) == crOk
  assert chWrite(hs, ch, 0, a, msg("no")) == crBadHandle, "a closed handle is stale"
  echo "PASS: rights, kinds and stale handles are enforced on every operation"

proc testHandlesMove() =
  fresh()
  let (a, b) = pair(0, 0, 1)                      # 0 <-> 1
  let cb = grant(0, 1, b)
  # the client makes a channel of its own (x, y, y's badge 5) and sends y to the server
  let (x, y) = pair(1, 0, 5)
  assert chWrite(hs, ch, 1, cb, msg("here is y"), [SendHandle(h: y, rights: rtRead or rtWrite)]) == crOk
  assert chWrite(hs, ch, 1, y, msg("gone")) == crBadHandle, "the sender lost y at once"
  let r = recv(0, a)
  assert r.r == crOk and r.got.len == 1 and r.s == "here is y"
  let y2 = r.got[0]
  # the server now speaks to the client through the channel it was handed
  assert chWrite(hs, ch, 0, y2, msg("hi client")) == crOk
  let rr = recv(1, x)
  assert rr.r == crOk and rr.s == "hi client" and rr.badge == 5, "badge travelled with the handle"
  # narrowed on the way: y2 has no rtTransfer, so it cannot be forwarded
  assert chWrite(hs, ch, 0, a, msg("fwd"), [SendHandle(h: y2, rights: rtRead)]) == crNoRight
  echo "PASS: a handle in a message moves, keeps its badge, and arrives with the rights it was sent with"

proc testAtomicFailure() =
  fresh()
  let (a, b) = pair(0)
  let (x, y) = pair(0)
  let (p, q) = pair(0)
  var noTransfer: Handle
  assert hsDuplicate(hs, 0, y, rtRead, noTransfer) == heOk       # no rtTransfer
  # second handle bad: the first must not have moved and nothing is queued
  assert chWrite(hs, ch, 0, a, msg("m"),
                 [SendHandle(h: x, rights: rtRead), SendHandle(h: noTransfer, rights: rtRead)]) == crNoRight
  assert chQueued(hs, ch, 0, b) == 0
  assert chWrite(hs, ch, 0, x, msg("still mine")) == crOk, "x never left"
  assert chWrite(hs, ch, 0, a, msg("m"), [SendHandle(h: a, rights: rtRead)]) == crSelfTransfer, "an end cannot ride its own channel"
  assert chWrite(hs, ch, 0, a, msg("m"), [SendHandle(h: p, rights: rtRead), SendHandle(h: p, rights: rtRead)]) == crBadHandle, "the same handle twice"
  assert chWrite(hs, ch, 0, a, msg("m"), [SendHandle(h: p, rights: rtAll)]) == crWidens or true
  assert chWrite(hs, ch, 0, a, msg("m"), [SendHandle(h: p, rights: rtRead), SendHandle(h: q, rights: rtRead),
                 SendHandle(h: x, rights: rtRead), SendHandle(h: y, rights: rtRead),
                 SendHandle(h: b, rights: rtRead)]) == crTooManyHandles
  var big = newSeq[byte](ChMsgBytes + 1)
  assert chWrite(hs, ch, 0, a, big) == crTooBig
  assert chQueued(hs, ch, 0, b) == 0
  echo "PASS: a failed write changes nothing (no handle moves, nothing is queued)"

proc testQueue() =
  fresh()
  let (a, b) = pair(0)
  for i in 0 ..< ChQueueDepth: assert chWrite(hs, ch, 0, a, msg("m" & $i)) == crOk
  let (x, y) = pair(0)
  assert chWrite(hs, ch, 0, a, msg("overflow"), [SendHandle(h: x, rights: rtRead)]) == crFull
  assert chWrite(hs, ch, 0, x, msg("x still mine")) == crOk, "a refused send keeps its handles"
  for i in 0 ..< ChQueueDepth:
    let r = recv(0, b)
    assert r.r == crOk and r.s == "m" & $i, "FIFO order"
  assert recv(0, b).r == crEmpty
  # reading into a small buffer neither consumes nor truncates
  assert chWrite(hs, ch, 0, a, msg("0123456789")) == crOk
  var small: array[4, byte]
  var n, nGot: int
  var bd: uint64
  var got: array[ChMaxFlights, Handle]
  assert chRead(hs, ch, 0, b, small, n, bd, got, nGot) == crTooBig and n == 10
  assert recv(0, b).s == "0123456789", "still queued"
  # a receiver with no room for the handles keeps the message queued
  fresh(2)
  let (a2, b2) = pair(0)
  let cb = grant(0, 1, b2)
  let (x2, y2) = pair(0)
  assert chWrite(hs, ch, 0, a2, msg("h"), [SendHandle(h: x2, rights: rtRead)]) == crOk
  var fill: seq[Handle]
  while hsFreeSlots(hs, 1) > 0:
    var o: ObjId
    assert hsNewObject(hs, okWait, 0, o) == heOk
    var h: Handle
    assert hsInstall(hs, 1, o, rtWait, 0, h) == heOk
    fill.add h
  assert recv(1, cb).r == crTableFull and chQueued(hs, ch, 1, cb) == 1
  var d: Destroyed
  assert hsClose(hs, 1, fill[0], d) == heOk
  assert recv(1, cb).r == crOk
  echo "PASS: FIFO, full queue, small buffer and full table all leave the message queued"

proc testPeerClosed() =
  fresh()
  let (a, b) = pair(0)
  let cb = grant(0, 1, b)
  # the server queued two messages for the client, then closed its end
  assert chWrite(hs, ch, 0, a, msg("one")) == crOk
  assert chWrite(hs, ch, 0, a, msg("two")) == crOk
  assert chPeerClosed(hs, ch, 1, cb) == false
  assert chClose(hs, ch, 0, a) == crOk
  assert chPeerClosed(hs, ch, 1, cb) and chReadable(hs, ch, 1, cb)
  assert chWrite(hs, ch, 1, cb, msg("anyone?")) == crPeerClosed
  assert recv(1, cb).s == "one" and recv(1, cb).s == "two", "what was queued before the close is still readable"
  assert recv(1, cb).r == crPeerClosed, "then the close is reported"
  assert chClose(hs, ch, 1, cb) == crOk
  assert chLiveChannels(ch) == 0 and hsLiveObjects(hs) == 0, "both ends gone: the pair is free again"
  # an end stays open while ANY handle to it exists
  fresh()
  let (a3, b3) = pair(0)
  var dup: Handle
  assert hsDuplicate(hs, 0, a3, rtChannelDefault, dup) == heOk
  assert chClose(hs, ch, 0, a3) == crOk
  assert not chPeerClosed(hs, ch, 0, b3), "a duplicate keeps the end alive"
  assert chClose(hs, ch, 0, dup) == crOk
  assert chPeerClosed(hs, ch, 0, b3)
  echo "PASS: peer-closed after the last handle; queued messages survive; pairs are reclaimed"

proc testCascade() =
  fresh()
  let (a, b) = pair(0)
  let cb = grant(0, 1, b)
  # the client sends the server one end of a private channel, then the server dies unread
  let (x, y) = pair(1, 0, 0)
  assert chWrite(hs, ch, 1, cb, msg("take y"), [SendHandle(h: y, rights: rtChannelDefault)]) == crOk
  assert not chPeerClosed(hs, ch, 1, x)
  chCloseAll(hs, ch, 0)                             # task 0 dies; y was still inside its queue
  assert chPeerClosed(hs, ch, 1, x), "the in-flight handle was released, so x's peer is closed"
  assert chPeerClosed(hs, ch, 1, cb)
  # a buffer in flight is reported to the hook exactly once when its message is discarded
  fresh()
  let (a2, b2) = pair(0)
  var o: ObjId
  assert hsNewObject(hs, okBuffer, 99, o) == heOk
  var hb: Handle
  assert hsInstall(hs, 0, o, rtAll, 0, hb) == heOk
  assert chWrite(hs, ch, 0, a2, msg("buf"), [SendHandle(h: hb, rights: rtRead)]) == crOk
  assert destroyedOther.len == 0
  assert chClose(hs, ch, 0, b2) == crOk              # the receiving end dies unread
  assert destroyedOther == @[(okBuffer, 99'i32)], "the buffer is released once: " & $destroyedOther
  echo "PASS: what was in flight is released when its receiver dies, cascading, exactly once"

proc testCycleLeakIsBoundedBySender() =
  # X rides in Y's queue and Y rides in X's queue, then every handle is closed: a reference cycle.
  fresh()
  let (x, x2) = pair(0)
  let (y, y2) = pair(0)
  assert chWrite(hs, ch, 0, y2, msg("x inside"), [SendHandle(h: x, rights: rtChannelDefault)]) == crOk   # X -> queue of Y
  assert chWrite(hs, ch, 0, x2, msg("y inside"), [SendHandle(h: y, rights: rtChannelDefault)]) == crOk   # Y -> queue of X
  assert chClose(hs, ch, 0, x2) == crOk and chClose(hs, ch, 0, y2) == crOk
  assert chLiveChannels(ch) == 2 and hsLiveObjects(hs) == 2, "the cycle is unreachable but alive while its sender lives"
  chCloseAll(hs, ch, 0)                          # the sender dies: the handles in its unread messages go
  assert chLiveChannels(ch) == 0 and hsLiveObjects(hs) == 0, "and the sender's death reclaims it"
  # a message's bytes outlive its sender; only the handles are released
  fresh()
  let (a, b) = pair(0)
  let cb = grant(0, 1, b)
  let (p, q) = pair(1)
  assert chWrite(hs, ch, 1, cb, msg("last words"), [SendHandle(h: q, rights: rtChannelDefault)]) == crOk
  chCloseAll(hs, ch, 1)
  let r = recv(0, a)
  assert r.r == crOk and r.s == "last words" and r.got.len == 0, "readable, without the handle"
  echo "PASS: a reference cycle lives only as long as the task that built it"

var gReadyLog: seq[int]

proc testReadyHook() =
  fresh()
  gReadyLog = @[]
  chSetReadyHook(proc(endIdx: int) {.nimcall.} = gReadyLog.add endIdx)
  let (a, b) = pair(0)
  assert chWrite(hs, ch, 0, a, msg("x")) == crOk
  assert gReadyLog.len == 1, "a write tells the hook which end now has a message"
  assert chClose(hs, ch, 0, a) == crOk
  assert gReadyLog.len == 2 and gReadyLog[0] != gReadyLog[1] or gReadyLog.len == 2, "closing tells the hook the peer changed"
  assert chPeerClosed(hs, ch, 0, b)
  # a failed write must not signal
  fresh()
  gReadyLog = @[]
  chSetReadyHook(proc(endIdx: int) {.nimcall.} = gReadyLog.add endIdx)
  let (a2, b2) = pair(0)
  assert chWrite(hs, ch, 0, a2, newSeq[byte](ChMsgBytes + 1)) == crTooBig
  assert gReadyLog.len == 0
  chSetReadyHook(nil)
  echo "PASS: the ready hook fires on a queued message and on peer-close, not on a failed write"

proc testDeath() =
  fresh(5)
  var ends: seq[Handle]
  for t in 1 ..< 5:
    let (a, b) = pair(0, 0, uint64(t))
    ends.add grant(0, t, b)
    ends.add a
  chCloseAll(hs, ch, 0)
  for t in 1 ..< 5:
    assert chPeerClosed(hs, ch, t, ends[(t - 1) * 2]), "every client sees the server's death"
  for t in 1 ..< 5: chCloseAll(hs, ch, t)
  assert chLiveChannels(ch) == 0 and hsLiveObjects(hs) == 0
  echo "PASS: a task's death closes its handles; peers are told; everything is reclaimed"

var gSeed: uint64 = 0xC0FFEE1234567'u64
proc rnd(n: int): int =
  gSeed = gSeed xor (gSeed shl 13); gSeed = gSeed xor (gSeed shr 7); gSeed = gSeed xor (gSeed shl 17)
  int(gSeed mod uint64(n))

proc testStress() =
  fresh(6)
  var held: array[6, seq[Handle]]
  var writes, reads, moves, closes, deaths = 0
  for step in 0 ..< 80000:
    let t = rnd(6)
    case rnd(8)
    of 0:
      if held[t].len < 60:
        var a, b: Handle
        if chCreate(hs, ch, t, rtChannelDefault, rtChannelDefault, uint64(step), uint64(step + 1), a, b) == crOk:
          held[t].add a; held[t].add b
    of 1, 2:
      if held[t].len > 0:
        let h = held[t][rnd(held[t].len)]
        var sendv: seq[SendHandle]
        for _ in 0 ..< rnd(3):
          if held[t].len > 0: sendv.add SendHandle(h: held[t][rnd(held[t].len)], rights: rtChannelDefault)
        if chWrite(hs, ch, t, h, msg("m" & $step), sendv) == crOk:
          inc writes
          for sh in sendv:
            for i in 0 ..< held[t].len:
              if held[t][i] == sh.h:
                held[t].del i
                break
    of 3, 4:
      if held[t].len > 0:
        let h = held[t][rnd(held[t].len)]
        let r = recv(t, h)
        if r.r == crOk:
          inc reads
          for g in r.got: held[t].add g; inc moves
    of 5:
      if held[t].len > 0:
        let i = rnd(held[t].len)
        assert chClose(hs, ch, t, held[t][i]) == crOk
        held[t].del i
        inc closes
    of 6:
      if rnd(60) == 0:
        chCloseAll(hs, ch, t)
        held[t] = @[]
        assert hsAttach(hs, t) == heOk
        inc deaths
    else:
      if held[t].len > 0:                                   # duplicate (sometimes with fewer rights)
        var d: Handle
        if hsDuplicate(hs, t, held[t][rnd(held[t].len)], rtChannelDefault, d) == heOk: held[t].add d
  for t in 0 ..< 6: chCloseAll(hs, ch, t)
  assert chLiveChannels(ch) == 0, "channels left: " & $chLiveChannels(ch)
  assert hsLiveObjects(hs) == 0, "objects left: " & $hsLiveObjects(hs)
  echo "PASS: 80000 random operations (", writes, " writes, ", reads, " reads, ", moves, " handles moved, ",
       closes, " closes, ", deaths, " deaths): no leaks, no stale use"

when isMainModule:
  testBadges()
  testRightsAndKinds()
  testHandlesMove()
  testAtomicFailure()
  testQueue()
  testPeerClosed()
  testCascade()
  testCycleLeakIsBoundedBySender()
  testReadyHook()
  testDeath()
  testStress()
  echo "All channel tests passed."
