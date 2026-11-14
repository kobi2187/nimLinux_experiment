# SPDX-License-Identifier: GPL-2.0
## Tests for per-task handle tables (ipc/handles/handle_table.nim): unforgeability, conservation of
## authority, movement, ownership, and the cost of the hot path.
import std/[monotimes, times]
import ../ipc/handles/handle_table

var gSeed: uint64 = 0x9E3779B97F4A7C15'u64
proc rnd(): uint64 =
  gSeed = gSeed xor (gSeed shl 13); gSeed = gSeed xor (gSeed shr 7); gSeed = gSeed xor (gSeed shl 17)
  gSeed
proc rndInt(n: int): int = int(rnd() mod uint64(n))

var hs: HandleSpace

proc fresh(tasks: int = 4) =
  hsInit(hs)
  for t in 0 ..< tasks: assert hsAttach(hs, t) == heOk

proc newObj(kind: ObjKind; payload: int32 = 0): ObjId =
  var o: ObjId
  assert hsNewObject(hs, kind, payload, o) == heOk
  o

proc give(t: TaskId; o: ObjId; r: Rights; badge: uint64 = 0): Handle =
  var h: Handle
  assert hsInstall(hs, t, o, r, badge, h) == heOk
  h

proc look(t: TaskId; h: Handle; kind: ObjKind; need: Rights): HsError =
  var o: ObjId
  var b: uint64
  hsLookup(hs, t, h, kind, need, o, b)

proc testBasics() =
  fresh()
  let ch = newObj(okChannelEnd, 7)
  let h = give(0, ch, rtRead or rtWrite or rtDuplicate, 42)
  var o: ObjId
  var badge: uint64
  assert hsLookup(hs, 0, h, okChannelEnd, rtRead, o, badge) == heOk and o == ch and badge == 42
  assert look(0, h, okBuffer, rtRead) == heWrongType, "right handle, wrong kind of object"
  assert look(0, h, okChannelEnd, rtTransfer) == heNoRight, "right kind, missing right"
  assert look(1, h, okChannelEnd, rtRead) == heBadHandle, "another task's table does not know it"
  assert look(0, NoHandle, okChannelEnd, rtNone) == heBadHandle, "0 is never a handle"
  # duplicate: narrows, never widens
  var h2: Handle
  assert hsDuplicate(hs, 0, h, rtRead, h2) == heOk
  assert look(0, h2, okChannelEnd, rtRead) == heOk and look(0, h2, okChannelEnd, rtWrite) == heNoRight
  var h3: Handle
  assert hsDuplicate(hs, 0, h2, rtRead, h3) == heNoRight, "a duplicate without rtDuplicate cannot duplicate"
  assert hsDuplicate(hs, 0, h, rtRead or rtTransfer, h3) == heWidens, "cannot add a right the original lacks"
  assert hsObjRefs(hs, ch) == 2
  # close: stale value dies, the slot's reuse yields a different value
  var d: Destroyed
  assert hsClose(hs, 0, h2, d) == heOk and not d.happened
  assert look(0, h2, okChannelEnd, rtRead) == heBadHandle, "a closed handle is stale"
  let h4 = give(0, ch, rtRead)
  assert h4 != h2, "reusing the slot gives a new generation, so the old value stays dead"
  assert hsClose(hs, 0, h, d) == heOk and hsClose(hs, 0, h4, d) == heOk
  assert d.happened and d.kind == okChannelEnd and d.payload == 7, "the last close reports the destroyed object"
  assert hsLiveObjects(hs) == 0
  echo "PASS: lookup, wrong kind/right/task, narrowing only, stale handles, last close"

proc testTransfer() =
  fresh()
  let ob = newObj(okBuffer, 3)
  let h = give(0, ob, rtRead or rtWrite or rtTransfer, 9)
  var f: Flight
  assert hsTransferOut(hs, 0, h, rtRead or rtWrite or rtMap, f) == heWidens, "cannot widen in flight"
  assert look(0, h, okBuffer, rtRead) == heOk, "a refused transfer leaves the handle in place"
  assert hsTransferOut(hs, 0, h, rtRead, f) == heOk
  assert look(0, h, okBuffer, rtRead) == heBadHandle, "the sender has lost it at once"
  assert hsObjRefs(hs, ob) == 1, "the flight holds the reference"
  var h2: Handle
  assert hsTransferIn(hs, 1, f, h2) == heOk
  var o: ObjId
  var b: uint64
  assert hsLookup(hs, 1, h2, okBuffer, rtRead, o, b) == heOk and b == 9, "the badge travels with the handle"
  assert look(1, h2, okBuffer, rtWrite) == heNoRight, "narrowed to read only"
  assert look(1, h2, okBuffer, rtTransfer) == heNoRight, "and it cannot be passed on again"
  # no rtTransfer, no transfer
  let h3 = give(0, newObj(okBuffer), rtRead)
  assert hsTransferOut(hs, 0, h3, rtRead, f) == heNoRight
  # a dropped flight releases the object
  let h4 = give(0, newObj(okBuffer, 5), rtTransfer or rtRead)
  assert hsTransferOut(hs, 0, h4, rtRead, f) == heOk
  var d: Destroyed
  hsDropFlight(hs, f, d)
  assert d.happened and d.payload == 5 and hsLiveObjects(hs) == 2
  # a full table refuses delivery and keeps the flight valid
  fresh(2)
  let src = newObj(okBuffer)
  let hh = give(0, src, rtTransfer or rtRead)
  assert hsTransferOut(hs, 0, hh, rtRead, f) == heOk
  var filler: seq[Handle]
  for i in 0 ..< HsMaxHandles: filler.add give(1, newObj(okWait), rtWait)
  assert hsFreeSlots(hs, 1) == 0
  assert hsTransferIn(hs, 1, f, h2) == heTableFull
  assert hsObjRefs(hs, src) == 1, "still held by the flight"
  hsCloseAll(hs, 1)
  assert hsAttach(hs, 1) == heOk
  assert hsTransferIn(hs, 1, f, h2) == heOk, "delivers once there is room"
  echo "PASS: transfer moves, narrows, carries the badge; dropped and refused flights keep ownership straight"

proc testNoForgery() =
  # Exhaustive sweep of the value space a guesser would try: only the issued handles work.
  fresh()
  var issued: seq[Handle]
  for i in 0 ..< 12: issued.add give(0, newObj(okChannelEnd), rtRead)
  var d: Destroyed
  for i in 0 ..< 4:                       # churn so generations move on
    assert hsClose(hs, 0, issued[i], d) == heOk
    issued[i] = give(0, newObj(okChannelEnd), rtRead)
  var hits = 0
  var o: ObjId
  var b: uint64
  for gen in 0 ..< 3000:
    for slot in 0 ..< 300:
      let v = Handle((uint32(gen) shl 16) or uint32(slot))
      if hsLookup(hs, 0, v, okChannelEnd, rtNone, o, b) == heOk: inc hits
      if hsLookup(hs, 1, v, okChannelEnd, rtNone, o, b) == heOk: assert false, "a guess worked in an empty table"
  assert hits == issued.len, "exactly the issued handles resolve: " & $hits
  # other tasks' valid values are not valid here unless identical AND issued here
  let other = give(1, newObj(okChannelEnd), rtRead)
  assert look(2, other, okChannelEnd, rtNone) == heBadHandle
  echo "PASS: ", 3000 * 300, " guessed values: only the ", issued.len, " issued handles resolve"

type Sh = object
  h: Handle
  o: ObjId
  r: Rights
  b: uint64

var model: array[HsMaxTasks, seq[Sh]]
var flights: seq[tuple[f: Flight, r: Rights]]

proc checkRefs() =
  var cnt: array[HsMaxObjs, int]
  for t in 0 ..< 6:
    for e in model[t]: inc cnt[int(int32(e.o))]
  for f in flights: inc cnt[int(int32(f.f.obj))]
  for i in 0 ..< HsMaxObjs:
    assert hsObjRefs(hs, ObjId(i)) == cnt[i], "refcount of object " & $i & ": " & $hsObjRefs(hs, ObjId(i)) & " vs " & $cnt[i]
  var live = 0
  for i in 0 ..< HsMaxObjs:
    if cnt[i] > 0: inc live
  assert hsLiveObjects(hs) == live, "live objects"

proc testRandomAgainstModel() =
  fresh(6)
  for t in 0 ..< 6: model[t] = @[]
  flights = @[]
  const Kinds = [okChannelEnd, okBuffer, okPortClient, okWait]
  for step in 0 ..< 60000:
    let t = rndInt(6)
    case rndInt(9)
    of 0, 1:                                           # new object, one handle
      if model[t].len < 100:
        let k = Kinds[rndInt(4)]
        var o: ObjId
        assert hsNewObject(hs, k, int32(step), o) == heOk
        let r = Rights(uint32(rnd()) and uint32(rtAll))
        var h: Handle
        let bg = rnd()
        assert hsInstall(hs, t, o, r, bg, h) == heOk
        model[t].add Sh(h: h, o: o, r: r, b: bg)
    of 2:                                              # duplicate with a random (maybe widening) mask
      if model[t].len > 0:
        let i = rndInt(model[t].len)
        let e = model[t][i]
        let want = Rights(uint32(rnd()) and uint32(rtAll))
        var h2: Handle
        let rc = hsDuplicate(hs, t, e.h, want, h2)
        if not e.r.has(rtDuplicate): assert rc == heNoRight
        elif not want.subsetOf(e.r): assert rc == heWidens
        else:
          assert rc == heOk
          model[t].add Sh(h: h2, o: e.o, r: want, b: e.b)
    of 3:                                              # close
      if model[t].len > 0:
        let i = rndInt(model[t].len)
        var d: Destroyed
        assert hsClose(hs, t, model[t][i].h, d) == heOk
        model[t].del i
    of 4:                                              # transfer out
      if model[t].len > 0:
        let i = rndInt(model[t].len)
        let e = model[t][i]
        let want = Rights(uint32(rnd()) and uint32(e.r))
        var f: Flight
        let rc = hsTransferOut(hs, t, e.h, want, f)
        if not e.r.has(rtTransfer): assert rc == heNoRight
        else:
          assert rc == heOk
          flights.add (f: f, r: want)
          model[t].del i
    of 5:                                              # transfer in
      if flights.len > 0:
        let i = rndInt(flights.len)
        var h: Handle
        let rc = hsTransferIn(hs, t, flights[i].f, h)
        if rc == heOk:
          model[t].add Sh(h: h, o: flights[i].f.obj, r: flights[i].f.rights, b: flights[i].f.badge)
          flights.del i
        else: assert rc == heTableFull
    of 6:                                              # drop a flight
      if flights.len > 0:
        let i = rndInt(flights.len)
        var d: Destroyed
        hsDropFlight(hs, flights[i].f, d)
        flights.del i
    of 7:                                              # a task dies and is replaced
      if rndInt(40) == 0:
        hsCloseAll(hs, t)
        model[t] = @[]
        assert hsAttach(hs, t) == heOk
    else:                                              # probes: truth is the model, nothing else
      for _ in 0 ..< 8:
        var h: Handle
        case rndInt(3)
        of 0: h = Handle(uint32(rnd()))
        of 1:
          let u = rndInt(6)
          h = (if model[u].len > 0: model[u][rndInt(model[u].len)].h else: Handle(rnd() and 0xFFFFFF'u64))
        else: h = (if model[t].len > 0: model[t][rndInt(model[t].len)].h else: NoHandle)
        var expectKind = okNone
        var expectRights = rtNone
        for e in model[t]:
          if e.h == h:
            expectKind = hsObjKind(hs, e.o); expectRights = e.r
        var o: ObjId
        var b: uint64
        if expectKind == okNone:
          assert hsLookup(hs, t, h, okChannelEnd, rtNone, o, b) in [heBadHandle], "a handle that is not in this table resolved"
        else:
          assert hsLookup(hs, t, h, expectKind, expectRights, o, b) == heOk
    if step mod 997 == 0: checkRefs()
  checkRefs()
  for f in flights:
    var d: Destroyed
    hsDropFlight(hs, f.f, d)
  flights = @[]
  for t in 0 ..< 6: hsCloseAll(hs, t)
  assert hsLiveObjects(hs) == 0, "everything released: " & $hsLiveObjects(hs)
  echo "PASS: 60000 random operations agree with an independent model; refcounts exact; nothing leaks"

proc testCost() =
  fresh()
  let h = give(0, newObj(okChannelEnd), rtRead or rtWrite)
  var o: ObjId
  var b: uint64
  const N = 2_000_000
  var ok = 0
  let t0 = getMonoTime()
  for i in 0 ..< N:
    if hsLookup(hs, 0, h, okChannelEnd, rtRead, o, b) == heOk: inc ok
  let ns = float((getMonoTime() - t0).inNanoseconds) / float(N)
  assert ok == N
  # Information only. Wall-clock time is never asserted here: shared CI and instrumenting tools
  # (valgrind, ASan) make it vary by orders of magnitude (1.1 ns native, ~1500 ns under valgrind).
  # The cost argument is structural (one index, one generation compare, one kind compare, one
  # rights test; no loop, no allocation) and is measured on the real target by the benchmark.
  echo "INFO: handle lookup (index, generation, kind, rights): ", ns, " ns each on this host"
  echo "PASS: the hot path returns the right answer ", N, " times"

when isMainModule:
  testBasics()
  testTransfer()
  testNoForgery()
  testRandomAgainstModel()
  testCost()
  echo "All handle table tests passed."
