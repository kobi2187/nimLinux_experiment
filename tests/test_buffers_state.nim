# SPDX-License-Identifier: GPL-2.0
## buffers B2 — ownership state machine (ipc/buffers/state.nim).
## Scenario tests pin the semantics; the property test is the definition of
## done: random operation sequences across tasks never break an invariant,
## and when every task exits nothing is left (no leak, no stray charge).

import std/[unittest, random]
import ../ipc/buffers/types
import ../ipc/buffers/state

const KB = 1024
var s: BufStore                                    # big: a global

proc fresh(tasks = 3; budget = 64 * KB) =
  s.initStore(0x4000_0000'u64, granule = KB, blocks = 64)   # 64 KB test arena
  for t in 0 ..< tasks: check s.taskAttach(t, budget) == beOk

proc newBuf(t: TaskId; size = 4 * KB): BufHandle =
  check s.bufCreate(t, size, result) == beOk

proc send(t: TaskId; h: BufHandle; mode: TransferMode): InFlightId =
  check s.bufSend(t, h, mode, result) == beOk

proc deliver(f: InFlightId; t: TaskId; transit = false): BufHandle =
  check s.bufDeliver(f, t, transit, result) == beOk

template ok() = check s.checkInvariants() == ""

suite "buffers state: scenarios":
  test "create: owner has read-write; budget charged; others have nothing":
    fresh()
    let h = newBuf(0)
    check s.access(0, h) == acReadWrite and s.access(1, h) == acNone
    check s.budgetLeft(0) == 60 * KB
    ok()

  test "move: the sender loses access at send time, the receiver owns it and pays":
    fresh()
    let h = newBuf(0)
    let f = send(0, h, tmMove)
    check s.access(0, h) == acNone                 # handle already gone (Zircon)
    let r = deliver(f, 1)
    check s.access(1, r) == acReadWrite
    check s.budgetLeft(0) == 64 * KB and s.budgetLeft(1) == 60 * KB
    ok()

  test "lend: lender has no access meanwhile; return restores sole access":
    fresh()
    let h = newBuf(0)
    let r = deliver(send(0, h, tmLend), 1)
    check s.access(0, h) == acNone and s.access(1, r) == acReadWrite
    check s.bufReturn(1, r) == beOk
    check s.access(0, h) == acReadWrite and s.access(1, r) == acNone
    check s.budgetLeft(1) == 64 * KB               # a lend never moves the charge
    ok()

  test "a borrower cannot pass the buffer on":
    fresh()
    let r = deliver(send(0, newBuf(0), tmLend), 1)
    var f: InFlightId
    check s.bufSend(1, r, tmMove, f) == beNotOwned
    check s.bufSend(1, r, tmLend, f) == beNotOwned
    ok()

  test "seal + share: read-only for everyone, including the creator":
    fresh()
    let h = newBuf(0)
    check s.bufSeal(0, h) == beOk
    let r1 = deliver(send(0, h, tmShare), 1)
    let r2 = deliver(send(0, h, tmShare), 2)
    check s.access(0, h) == acRead and s.access(1, r1) == acRead and s.access(2, r2) == acRead
    var f: InFlightId
    check s.bufSend(0, h, tmLend, f) == beNotOwned # sealed can't be lent
    ok()

  test "share of an unsealed buffer is refused":
    fresh()
    var f: InFlightId
    check s.bufSend(0, newBuf(0), tmShare, f) == beNotOwned

  test "dispatcher transit: forwards, never accesses":
    fresh()
    let h = newBuf(0)
    let d = deliver(send(0, h, tmLend), 2, transit = true)   # 2 = dispatcher
    check s.access(2, d) == acNone
    let r = deliver(send(2, d, tmMove), 1)                     # mode param ignored: inner lend
    check s.access(1, r) == acReadWrite and s.access(2, d) == acNone
    check s.bufReturn(1, r) == beOk and s.access(0, h) == acReadWrite
    ok()

  test "borrower exit auto-returns the lend":
    fresh()
    let h = newBuf(0)
    discard deliver(send(0, h, tmLend), 1)
    s.taskExit(1)
    check s.access(0, h) == acReadWrite
    ok()

  test "lender exit mid-lend: the borrower keeps it; freed on return":
    fresh()
    let r = deliver(send(0, newBuf(0), tmLend), 1)
    s.taskExit(0)
    check s.access(1, r) == acReadWrite and s.liveBuffers == 1
    check s.bufReturn(1, r) == beOk
    check s.liveBuffers == 0
    ok()

  test "cancelled move is lost; cancelled lend returns":
    fresh()
    check s.bufCancel(send(0, newBuf(0), tmMove)) == beOk
    check s.liveBuffers == 0 and s.budgetLeft(0) == 64 * KB
    let h = newBuf(0)
    check s.bufCancel(send(0, h, tmLend)) == beOk
    check s.access(0, h) == acReadWrite
    ok()

  test "budgets refuse creation and delivery; a failed delivery can be retried":
    fresh(budget = 8 * KB)
    var h: BufHandle
    check s.bufCreate(0, 16 * KB, h) == beNoBudget
    let big = newBuf(0, 8 * KB)
    discard newBuf(1, 6 * KB)
    let f = send(0, big, tmMove)
    var r: BufHandle
    check s.bufDeliver(f, 1, false, r) == beNoBudget          # 1 has 2 KB left
    check s.bufDeliver(f, 2, false, r) == beOk                # retry elsewhere
    ok()

  test "map: an address only while the caller has access":
    fresh()
    let h = newBuf(0, 3 * KB)
    var a: uint64
    var w: bool
    check s.bufMapAddr(0, h, a, w) == beOk and a == 0x4000_0000'u64 and w
    let r = deliver(send(0, h, tmLend), 1)
    check s.bufMapAddr(0, h, a, w) == beNoRight        # lent away
    check s.bufMapAddr(1, r, a, w) == beOk and a == 0x4000_0000'u64
    check s.budgetLeft(0) == 61 * KB                   # 3 blocks of 1 KB
    ok()

  test "a buffer costs the whole blocks it occupies":
    fresh()
    discard newBuf(0, 1500)                            # 2 blocks of 1 KB
    check s.budgetLeft(0) == 62 * KB
    ok()

  test "the arena running out is reported, not overcommitted":
    fresh(budget = 1024 * KB)
    var h: BufHandle
    check s.bufCreate(0, 60 * KB, h) == beOk
    check s.bufCreate(1, 8 * KB, h) == beNoBudget      # only 4 blocks left
    ok()

  test "stale and foreign handles are rejected (generations)":
    fresh()
    let h = newBuf(0)
    check s.bufClose(0, h) == beOk
    let h2 = newBuf(0)                             # same slot, next generation
    check h2 != h and s.access(0, h) == acNone
    check s.access(1, h2) == acNone                # handle values are per task
    check s.bufClose(0, h) == beBadHandle
    ok()

suite "buffers state: property test":
  test "random operation sequences keep every invariant and leak nothing":
    const Tasks = 4
    var steps = 0
    for seed in 1 .. 300:
      var rng = initRand(seed)
      fresh(Tasks, 48 * KB)
      var handles: seq[(TaskId, BufHandle)]
      var flights: seq[InFlightId]
      var alive: array[Tasks, bool]
      for t in 0 ..< Tasks: alive[t] = true
      proc pickHandle(): (TaskId, BufHandle) =
        if handles.len == 0 or rng.rand(9) == 0:      # sometimes garbage
          (rng.rand(Tasks - 1), BufHandle(uint32(rng.rand(0xFFFFF))))
        else: handles[rng.rand(handles.high)]
      for i in 0 ..< 150:
        inc steps
        let t = rng.rand(Tasks - 1)
        case rng.rand(9)
        of 0, 1:
          var h: BufHandle
          if s.bufCreate(t, (1 + rng.rand(7)) * KB, h) == beOk: handles.add((t, h))
        of 2, 3:
          let (ht, h) = pickHandle()
          var f: InFlightId
          if s.bufSend(ht, h, TransferMode(rng.rand(2)), f) == beOk: flights.add(f)
        of 4, 5:
          if flights.len > 0:
            let k = rng.rand(flights.high)
            var r: BufHandle
            if s.bufDeliver(flights[k], t, rng.rand(3) == 0, r) == beOk:
              handles.add((t, r)); flights.del(k)
        of 6:
          if flights.len > 0:
            let k = rng.rand(flights.high)
            check s.bufCancel(flights[k]) == beOk
            flights.del(k)
        of 7:
          let (ht, h) = pickHandle()
          discard s.bufSeal(ht, h)
        of 8:
          let (ht, h) = pickHandle()
          if rng.rand(1) == 0: discard s.bufReturn(ht, h)
          else: discard s.bufClose(ht, h)
        else:
          if rng.rand(4) == 0:                         # exit + restart a task
            s.taskExit(t)
            check s.taskAttach(t, 48 * KB) == beOk
        let v = s.checkInvariants()
        if v != "":
          checkpoint("seed " & $seed & " step " & $i & ": " & v)
          fail()
          break
      for f in flights: discard s.bufCancel(f)
      for t in 0 ..< Tasks: s.taskExit(t)
      check s.liveBuffers == 0                         # nothing leaked
      check s.inFlight == 0
    checkpoint($steps & " random steps")
