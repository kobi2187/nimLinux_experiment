# SPDX-License-Identifier: GPL-2.0
## Session rings (buffers B4) — the data plane for streams.
##
## Producer side: `ringPush` stages slots locally (no kernel call).
## `ringSubmit` is the ONE kernel call per batch: it validates every staged
## descriptor, moves each referenced buffer to the consumer (the producer's
## handle is gone at that instant), files the consumer's new handle in the
## ring's attached set, rewrites the descriptor to point there, enqueues the
## batch on the consumer queue (`ipc/mpsc_ring`) and counts ONE wake for the
## consumer actor. A bad descriptor is dropped alone; it never reaches the
## consumer and never touches memory.
##
## Inline slots (≤ InlineMax bytes) are plain copies: no handle, no flip.

import types
import state
import ../mpsc_ring

const
  RingSlots*   = 32          ## staged and queued slots per ring (power of two)
  MaxRings*    = 16
  RingAttached = 32          ## consumer handles awaiting ringTake

type
  Ring = object
    live: bool
    producer, consumer: TaskId
    staged: array[RingSlots, RingSlot]
    nStaged: int
    queue: MpscQueue[RingSlots, RingSlot]
    attached: array[RingAttached, BufHandle]
    wakes*: int              ## consumer wakeups posted (one per non-empty submit)
    submits*: int            ## kernel calls (one per ringSubmit)

  RingStore* = object
    rings: array[MaxRings, Ring]

  SubmitResult* = object
    accepted*, rejected*: int

func ringIndex(e: RingEnd): int = int(uint32(e) shr 1)
func isProducer(e: RingEnd): bool = (uint32(e) and 1) == 0

proc ringCreate*(rs: var RingStore; producer, consumer: TaskId;
                 p, c: var RingEnd): BufError =
  ## Session setup (the dispatcher decides who the two sides are).
  for i in 0 ..< MaxRings:
    if not rs.rings[i].live:
      rs.rings[i] = Ring(live: true, producer: producer, consumer: consumer)
      mpscInit(rs.rings[i].queue)
      p = RingEnd(uint32(i) shl 1)
      c = RingEnd((uint32(i) shl 1) or 1)
      return beOk
  beRingFull

proc ringOf(rs: var RingStore; e: RingEnd; t: TaskId; producer: bool): ptr Ring =
  ## The ring behind end e, if task t holds that end.
  let i = e.ringIndex
  if i notin 0 ..< MaxRings or not rs.rings[i].live or e.isProducer != producer:
    return nil
  let r = addr rs.rings[i]
  if (if producer: r.producer else: r.consumer) != t: return nil
  r

proc ringPush*(rs: var RingStore; t: TaskId; p: RingEnd; slot: RingSlot): BufError =
  let r = rs.ringOf(p, t, producer = true)
  if r == nil: return beBadHandle
  if r.nStaged >= RingSlots: return beRingFull
  r.staged[r.nStaged] = slot
  inc r.nStaged
  beOk

proc bufRefOf(slot: RingSlot): BufRef =
  copyMem(addr result, unsafeAddr slot.data[0], sizeof(BufRef))

proc setBufRef(slot: var RingSlot; r: BufRef) =
  copyMem(addr slot.data[0], unsafeAddr r, sizeof(BufRef))

proc freeAttached(r: Ring): int =
  for i in 0 ..< RingAttached:
    if r.attached[i] == NoHandle: return i
  -1

proc transferRef(s: var BufStore; r: var Ring; slot: var RingSlot): BufError =
  ## Validate a staged descriptor and move its buffer to the consumer.
  var br = bufRefOf(slot)
  let src = s.handleAt(r.producer, int(br.handleIdx))   # the producer's own handles only
  var size: int
  if s.bufSize(r.producer, src, size) != beOk: return beBadHandle
  if uint64(br.offset) + uint64(br.len) > uint64(size): return beBounds
  let k = r.freeAttached
  if k < 0: return beRingFull
  var f: InFlightId
  let mode = if (br.flags and 1) != 0: tmShare else: tmMove
  result = s.bufSend(r.producer, src, mode, f)
  if result != beOk: return
  var dst: BufHandle
  result = s.bufDeliver(f, r.consumer, false, dst)
  if result != beOk:
    discard s.bufCancel(f)                  # the move is lost, never duplicated
    return
  r.attached[k] = dst
  br.handleIdx = uint16(k)
  slot.setBufRef(br)

proc ringSubmit*(rs: var RingStore; s: var BufStore; t: TaskId; p: RingEnd): SubmitResult =
  ## ONE kernel call: flip ownership for the whole batch, then one wake.
  let r = rs.ringOf(p, t, producer = true)
  if r == nil: return
  inc r.submits
  for i in 0 ..< r.nStaged:
    var slot = r.staged[i]
    let ok = RingSlotKind(slot.kind) == rsInline and int(slot.len) <= InlineMax or
             RingSlotKind(slot.kind) == rsRef and s.transferRef(r[], slot) == beOk
    if ok and mpscEnqueue(r.queue, slot): inc result.accepted
    else: inc result.rejected
  r.nStaged = 0
  if result.accepted > 0: inc r.wakes

proc ringPop*(rs: var RingStore; t: TaskId; c: RingEnd; slot: var RingSlot): BufError =
  let r = rs.ringOf(c, t, producer = false)
  if r == nil: return beBadHandle
  if not mpscDequeue(r.queue, slot): return beRingEmpty
  beOk

proc ringTake*(rs: var RingStore; t: TaskId; c: RingEnd; br: BufRef): BufHandle =
  ## The consumer's handle for a popped descriptor (once; the slot is freed).
  let r = rs.ringOf(c, t, producer = false)
  if r == nil or int(br.handleIdx) >= RingAttached: return NoHandle
  result = r.attached[br.handleIdx]
  r.attached[br.handleIdx] = NoHandle

proc ringStats*(rs: RingStore; e: RingEnd): tuple[submits, wakes: int] =
  let i = e.ringIndex
  if i notin 0 ..< MaxRings: return
  (rs.rings[i].submits, rs.rings[i].wakes)

proc refSlot*(br: BufRef; tag = 0'u32): RingSlot =
  result.kind = uint8(rsRef)
  result.tag = tag
  result.setBufRef(br)

proc inlineSlot*(data: openArray[byte]; tag = 0'u32): RingSlot =
  assert data.len <= InlineMax
  result.kind = uint8(rsInline)
  result.tag = tag
  result.len = uint16(data.len)
  if data.len > 0: copyMem(addr result.data[0], unsafeAddr data[0], data.len)
