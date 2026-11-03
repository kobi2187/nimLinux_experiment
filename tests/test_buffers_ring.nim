# SPDX-License-Identifier: GPL-2.0
## buffers B4 — session rings (ipc/buffers/ring.nim): batched ownership
## transfer, one kernel call and one wake per batch, hostile descriptors.

import std/[unittest, random]
import ../ipc/buffers/types
import ../ipc/buffers/state
import ../ipc/buffers/ring

const KB = 1024
const Prod = 0
const Cons = 1
var s: BufStore
var rs: RingStore
var p, c: RingEnd

proc fresh() =
  s.initStore(0x4000_0000'u64, granule = KB, blocks = 64)
  rs = RingStore()
  check s.taskAttach(Prod, 64 * KB) == beOk
  check s.taskAttach(Cons, 64 * KB) == beOk
  check s.taskAttach(2, 64 * KB) == beOk
  check rs.ringCreate(Prod, Cons, p, c) == beOk

proc buf(size = 2 * KB): BufHandle =
  check s.bufCreate(Prod, size, result) == beOk

proc refTo(h: BufHandle; off, len: int; share = false): RingSlot =
  refSlot(BufRef(handleIdx: handleSlot(h), flags: (if share: 1'u16 else: 0'u16),
                 offset: uint32(off), len: uint32(len)))

template ok() = check s.checkInvariants() == ""

suite "buffers ring":
  test "a batch of N buffers: one submit, one wake, ownership flipped":
    fresh()
    var hs: seq[BufHandle]
    for i in 0 ..< 5:
      hs.add buf()
      check rs.ringPush(Prod, p, refTo(hs[^1], 0, 2 * KB)) == beOk
    check rs.ringSubmit(s, Prod, p).accepted == 5
    check rs.ringStats(p) == (1, 1)                         # 1 kernel call, 1 wake
    for h in hs: check s.access(Prod, h) == acNone          # gone at submit
    for i in 0 ..< 5:
      var slot: RingSlot
      check rs.ringPop(Cons, c, slot) == beOk
      var br: BufRef
      copyMem(addr br, addr slot.data[0], sizeof(br))
      let mine = rs.ringTake(Cons, c, br)
      check s.access(Cons, mine) == acReadWrite
    check s.budgetLeft(Cons) == 54 * KB                    # charges moved with ownership
    ok()

  test "inline payloads ride the ring without handles":
    fresh()
    check rs.ringPush(Prod, p, inlineSlot([1'u8, 2, 3], tag = 7)) == beOk
    check rs.ringSubmit(s, Prod, p).accepted == 1
    var slot: RingSlot
    check rs.ringPop(Cons, c, slot) == beOk
    check slot.tag == 7 and slot.len == 3 and slot.data[2] == 3
    ok()

  test "hostile descriptors are rejected alone and never move anything":
    fresh()
    let good = buf()
    let other = buf()
    var tiny: BufHandle
    check s.bufCreate(2, KB, tiny) == beOk                  # task 2's buffer
    check rs.ringPush(Prod, p, refTo(good, 0, 2 * KB)) == beOk
    check rs.ringPush(Prod, p, refTo(other, KB, 2 * KB)) == beOk       # out of bounds
    check rs.ringPush(Prod, p, refSlot(BufRef(handleIdx: 31))) == beOk # empty slot
    check rs.ringPush(Prod, p, refTo(tiny, 0, 1)) == beOk              # names slot of 2's table
    var bad = inlineSlot([])
    bad.len = 241                                           # inline too long
    check rs.ringPush(Prod, p, bad) == beOk
    let r = rs.ringSubmit(s, Prod, p)
    check r.accepted == 1 and r.rejected == 4               # slot 0 is Prod's own (already moved), never task 2's
    check s.access(Prod, other) == acReadWrite              # the out-of-bounds one stayed home
    check s.access(2, tiny) == acReadWrite
    ok()

  test "only the ends' holders may push or pop":
    fresh()
    check rs.ringPush(Cons, p, inlineSlot([])) == beBadHandle   # wrong task
    check rs.ringPush(Prod, c, inlineSlot([])) == beBadHandle   # consumer end
    var slot: RingSlot
    check rs.ringPop(Prod, c, slot) == beBadHandle
    check rs.ringPop(Cons, c, slot) == beRingEmpty

  test "sealed buffers can be shared through a ring; the producer keeps reading":
    fresh()
    let h = buf()
    check s.bufSeal(Prod, h) == beOk
    check rs.ringPush(Prod, p, refTo(h, 0, KB, share = true)) == beOk
    check rs.ringSubmit(s, Prod, p).accepted == 1
    check s.access(Prod, h) == acRead
    ok()

  test "a full consumer cannot make a move vanish twice (budget refusal)":
    fresh()
    check s.taskAttach(3, 0) == beOk                        # a consumer with no budget
    var p3, c3: RingEnd
    check rs.ringCreate(Prod, 3, p3, c3) == beOk
    let h = buf()
    check rs.ringPush(Prod, p3, refTo(h, 0, KB)) == beOk
    check rs.ringSubmit(s, Prod, p3).rejected == 1
    check s.liveBuffers == 0                                # move lost (cancelled), not duplicated
    ok()

  test "random batches keep every buffer invariant":
    var rng = initRand(11)
    for round in 0 ..< 200:
      fresh()
      var mine: seq[BufHandle]
      for i in 0 ..< 40:
        case rng.rand(3)
        of 0:
          var h: BufHandle
          if s.bufCreate(Prod, (1 + rng.rand(3)) * KB, h) == beOk: mine.add h
        of 1:
          let h = if mine.len > 0 and rng.rand(4) > 0: mine[rng.rand(mine.high)]
                  else: BufHandle(uint32(rng.rand(0xFFFFF)))
          discard rs.ringPush(Prod, p, refTo(h, rng.rand(3 * KB), rng.rand(3 * KB)))
        of 2:
          discard rs.ringSubmit(s, Prod, p)
        else:
          var slot: RingSlot
          if rs.ringPop(Cons, c, slot) == beOk and RingSlotKind(slot.kind) == rsRef:
            var br: BufRef
            copyMem(addr br, addr slot.data[0], sizeof(br))
            let got = rs.ringTake(Cons, c, br)
            if rng.rand(1) == 0: discard s.bufClose(Cons, got)
        let v = s.checkInvariants()
        if v != "":
          checkpoint("round " & $round & " step " & $i & ": " & v); fail(); break
