# SPDX-License-Identifier: GPL-2.0
## Actor performance benchmark. MUST compile --mm:arc --panics:on (nim-cps).
## Run with -d:release. Validates the cost model behind the CPS dispatcher:
##   1. deliver() round trip (plant -> resume -> handle -> re-park), ns/msg
##   2. direct proc call baseline -> actor overhead factor
##   3. bytes of heap per parked actor at scale (dispatcher = thousands parked)
##   4. leak check: heap flat across deliver rounds ({.cursor.} fix at scale)
##   5. mailbox post+recv (the other half of the dispatcher pipeline)
import std/[monotimes, times, strformat]
import ipc/mailbox
import runtime/actor
import cps

var gAccum: int

proc handle(m: MailMsg) = gAccum += int(m.data[0])

proc worker() {.cps: Actor.} =
  while true:
    suspend()
    handle(recv())

proc mkMsg(b: byte): MailMsg =
  result.len = 1
  result.data[0] = b

proc nsPerOp(t0, t1: MonoTime; ops: int): float =
  (t1 - t0).inNanoseconds.float / ops.float

proc benchDirect(ops: int): float =
  let msg = mkMsg(1)
  let t0 = getMonoTime()
  for _ in 0 ..< ops: handle(msg)
  result = nsPerOp(t0, getMonoTime(), ops)

proc benchDeliver(ops: int): float =
  var a = Actor(whelp worker())
  resume(a)                      # run to first suspend
  let msg = mkMsg(1)
  let base = gAccum
  let t0 = getMonoTime()
  for _ in 0 ..< ops: a.deliver(msg)
  result = nsPerOp(t0, getMonoTime(), ops)
  assert gAccum == base + ops, "every delivered message must be handled once"

proc parkActors(n: int): seq[Actor] =
  result = newSeq[Actor](n)
  for i in 0 ..< n:
    result[i] = Actor(whelp worker())
    resume(result[i])
    assert result[i].isSuspended

proc benchParkedHeap(n: int) =
  let before = getOccupiedMem()
  var actors = parkActors(n)
  let perActor = (getOccupiedMem() - before) div n
  echo &"parked heap        : {perActor} B/actor  ({n} actors, {(getOccupiedMem() - before) div 1024} KiB total)"

  # deliver one round at scale (cold caches across 100k actors)
  let msg = mkMsg(1)
  let t0 = getMonoTime()
  for a in actors: a.deliver(msg)
  echo &"deliver at scale   : {nsPerOp(t0, getMonoTime(), n):.1f} ns/msg  (1 round over {n} parked actors)"

  # leak check: heap must stay flat across repeated rounds
  let flat0 = getOccupiedMem()
  for _ in 0 ..< 10:
    for a in actors: a.deliver(msg)
  let growth = getOccupiedMem() - flat0
  echo &"leak check         : heap growth {growth} B after 10x{n} delivers (want 0)"
  assert growth == 0, "parked-actor heap must be flat — cursor fix regressed?"

proc benchMailbox(ops: int): float =
  var mb: Mailbox[64]
  mbInit(mb)
  let msg = mkMsg(1)
  let t0 = getMonoTime()
  for _ in 0 ..< ops:
    doAssert mbPost(mb, msg)
    doAssert mbTryRecv(mb).hasValue
  result = nsPerOp(t0, getMonoTime(), ops)

when isMainModule:
  const Ops = 1_000_000
  const Parked = 100_000
  let direct = benchDirect(Ops)
  let deliver = benchDeliver(Ops)
  let mbox = benchMailbox(Ops)
  echo &"direct call        : {direct:.1f} ns/msg (baseline)"
  echo &"actor deliver      : {deliver:.1f} ns/msg  ({deliver / max(direct, 0.1):.1f}x baseline)"
  echo &"mailbox post+recv  : {mbox:.1f} ns/msg"
  benchParkedHeap(Parked)
  echo "BENCH DONE"
