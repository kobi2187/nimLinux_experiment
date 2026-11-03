# SPDX-License-Identifier: GPL-2.0
## Buffer ownership state machine — the heart of subprojects/buffers (B2).
##
## Pure Nim, fixed tables, no allocation, no kernel imports: host-testable
## and `--os:any`. It decides WHO may access WHICH buffer and HOW; memory
## (arena), rings and per-model enforcement are layered on top.
##
## The rule (docs/proposals/bulk_data.md §2): an owned buffer is accessible
## by exactly one task at a time; a sealed buffer is read-only for all.
## Ownership changes only by move or lend. Handles leave the sender at send
## time (Zircon); a lend is a derived handle that the lender gets back on
## return, close or borrower exit (seL4-style revoke). Budgets follow
## ownership (Genode quota donation).

import types
import arena
export arena

const
  MaxBufs*     = 64      ## Stage A: one per 2 MB arena block at most
  MaxTasks*    = 32
  MaxHandles*  = 32      ## per task
  MaxInFlight* = 64      ## handles inside undelivered messages

type
  TaskId* = int          ## 0 ..< MaxTasks (the kernel maps pids to slots)
  InFlightId* = int

  HandleRole* = enum
    hrOwner      ## the owner's handle (no access while the buffer is lent)
    hrBorrower   ## derived by a lend; access until returned
    hrReader     ## a sealed buffer's read handle
    hrTransit    ## a forwarder's handle: may pass it on, may never access

  Handle = object
    used: bool
    gen: uint16
    buf: int
    role: HandleRole
    rights: BufRights
    innerMode: TransferMode    ## hrTransit: the mode it is travelling under

  Buf = object
    live: bool
    size: int
    state: BufState
    owner, borrower: TaskId    ## -1 = none / in transit
    lendWrite: bool
    run: BlockRun              ## its memory (whole arena blocks)
    refs: int                  ## handles + in-flight transfers naming it
    chargedTo: TaskId          ## -1 = orphaned charge (charged task exited)

  InFlight = object
    used: bool
    buf: int
    mode: TransferMode
    rights: BufRights
    sender: TaskId

  Task = object
    attached: bool
    budget, used: int
    handles: array[MaxHandles, Handle]

  BufStore* = object
    arena: Arena
    bufs: array[MaxBufs, Buf]
    tasks: array[MaxTasks, Task]
    flights: array[MaxInFlight, InFlight]

  Access* = enum
    acNone, acRead, acReadWrite

# ── handles ──────────────────────────────────────────────────────────────────

func encode(slot: int; gen: uint16): BufHandle =
  BufHandle((uint32(gen) shl 16) or uint32(slot + 1))

proc lookup(s: BufStore; t: TaskId; h: BufHandle): int =
  ## Slot of handle h in task t, or -1 (stale generation, unknown, closed).
  if t notin 0 ..< MaxTasks or not s.tasks[t].attached: return -1
  let slot = int(uint32(h) and 0xFFFF) - 1
  if slot notin 0 ..< MaxHandles: return -1
  let e = s.tasks[t].handles[slot]
  if not e.used or e.gen != uint16(uint32(h) shr 16): return -1
  slot

proc addHandle(s: var BufStore; t: TaskId; buf: int; role: HandleRole;
               rights: BufRights; inner = tmMove): BufHandle =
  for i in 0 ..< MaxHandles:
    if not s.tasks[t].handles[i].used:
      let gen = s.tasks[t].handles[i].gen + 1
      s.tasks[t].handles[i] = Handle(used: true, gen: gen, buf: buf, role: role,
                                     rights: rights, innerMode: inner)
      return encode(i, gen)
  NoHandle

proc dropHandle(s: var BufStore; t: TaskId; slot: int) =
  s.tasks[t].handles[slot].used = false   # gen survives: stale values stay stale

proc hasFreeHandle(s: BufStore; t: TaskId): bool =
  for e in s.tasks[t].handles:
    if not e.used: return true
  false

# ── budgets and lifetime ─────────────────────────────────────────────────────

proc cost(s: BufStore; b: int): int =
  ## What a buffer costs its owner: the whole blocks it occupies.
  s.arena.runBytes(s.bufs[b].run)

proc charge(s: var BufStore; b: int; t: TaskId) =
  s.bufs[b].chargedTo = t
  if t >= 0: s.tasks[t].used += s.cost(b)

proc uncharge(s: var BufStore; b: int) =
  let t = s.bufs[b].chargedTo
  if t >= 0: s.tasks[t].used -= s.cost(b)
  s.bufs[b].chargedTo = -1

proc unref(s: var BufStore; b: int) =
  ## Drop one reference; the last one frees the buffer and its charge.
  dec s.bufs[b].refs
  if s.bufs[b].refs == 0:
    s.uncharge(b)
    s.arena.freeRun(s.bufs[b].run)
    s.bufs[b].live = false

proc endLend(s: var BufStore; b: int) =
  ## The borrower's access ends; the lender has sole access again. If the
  ## lender closed its handle meanwhile, the caller's unref frees the buffer.
  s.bufs[b].borrower = -1
  s.bufs[b].state = bsOwned

# ── store / tasks ────────────────────────────────────────────────────────────

proc initStore*(s: var BufStore; base: uint64; granule, blocks: int) =
  ## The arena window the kernel mapped (Stage A: BlockSize × 64 = ArenaSize).
  ## In place: `s = BufStore()` would build a 32 KB temporary on the stack —
  ## twice the 16 KB boot stack, which sits right above the boot page tables.
  zeroMem(addr s, sizeof(s))
  s.arena = initArena(base, granule, blocks)

proc taskAttach*(s: var BufStore; t: TaskId; budget: int): BufError =
  if t notin 0 ..< MaxTasks or s.tasks[t].attached: return beBadHandle
  let gens = s.tasks[t].handles               # keep generations across reuse
  s.tasks[t] = Task(attached: true, budget: budget, handles: gens)
  for i in 0 ..< MaxHandles: s.tasks[t].handles[i].used = false
  beOk

proc budgetLeft*(s: BufStore; t: TaskId): int =
  if t notin 0 ..< MaxTasks or not s.tasks[t].attached: return 0
  s.tasks[t].budget - s.tasks[t].used

# ── create / access / seal ───────────────────────────────────────────────────

proc bufCreate*(s: var BufStore; t: TaskId; size: int; h: var BufHandle): BufError =
  h = NoHandle
  if t notin 0 ..< MaxTasks or not s.tasks[t].attached or size <= 0: return beBadHandle
  if s.budgetLeft(t) < s.arena.blocksFor(size) * s.arena.granule: return beNoBudget
  if not s.hasFreeHandle(t): return beTooManyHandles
  for b in 0 ..< MaxBufs:
    if not s.bufs[b].live:
      let run = s.arena.allocRun(size)
      if run.count == 0: return beNoBudget     # arena exhausted
      s.bufs[b] = Buf(live: true, size: size, state: bsOwned, owner: t,
                      borrower: -1, refs: 1, chargedTo: -1, run: run)
      s.charge(b, t)
      h = s.addHandle(t, b, hrOwner, {brRead, brWrite, brMap, brTransfer})
      return beOk
  beNoBudget                                  # arena of buffer objects full

proc access*(s: BufStore; t: TaskId; h: BufHandle): Access =
  ## What task t may do with the memory behind h RIGHT NOW.
  let slot = s.lookup(t, h)
  if slot < 0: return acNone
  let e = s.tasks[t].handles[slot]
  let b = s.bufs[e.buf]
  if brMap notin e.rights and brRead notin e.rights: return acNone
  case e.role
  of hrTransit: acNone
  of hrReader:  (if b.state == bsSealed: acRead else: acNone)
  of hrBorrower:
    if b.state != bsLent or b.borrower != t: acNone
    elif b.lendWrite: acReadWrite
    else: acRead
  of hrOwner:
    case b.state
    of bsSealed: acRead
    of bsLent:   acNone
    of bsOwned:  (if b.owner == t: acReadWrite else: acNone)

proc bufSize*(s: BufStore; t: TaskId; h: BufHandle; size: var int): BufError =
  let slot = s.lookup(t, h)
  if slot < 0: return beBadHandle
  size = s.bufs[s.tasks[t].handles[slot].buf].size
  beOk

proc bufMapAddr*(s: BufStore; t: TaskId; h: BufHandle; address: var uint64;
                 writable: var bool): BufError =
  ## Where the memory is — only while t may access it (bufMap's core).
  if s.access(t, h) == acNone: return beNoRight
  let b = s.tasks[t].handles[s.lookup(t, h)].buf
  address = s.arena.runAddr(s.bufs[b].run)
  writable = s.access(t, h) == acReadWrite
  beOk

proc bufSeal*(s: var BufStore; t: TaskId; h: BufHandle): BufError =
  ## owned → sealed: read-only for every holder, forever.
  let slot = s.lookup(t, h)
  if slot < 0: return beBadHandle
  let e = s.tasks[t].handles[slot]
  if e.role != hrOwner: return beNotOwned
  let b = e.buf
  if s.bufs[b].state == bsSealed: return beSealed
  if s.bufs[b].state != bsOwned or s.bufs[b].owner != t: return beNotOwned
  s.bufs[b].state = bsSealed
  s.tasks[t].handles[slot].rights.excl brWrite
  beOk

# ── transfer: send (handle leaves the sender) / deliver / cancel ─────────────

proc newFlight(s: var BufStore; f: InFlight): InFlightId =
  for i in 0 ..< MaxInFlight:
    if not s.flights[i].used:
      s.flights[i] = f
      s.flights[i].used = true
      return i
  -1

proc sendCheck(s: BufStore; e: Handle; t: TaskId; mode: TransferMode): BufError =
  let b = s.bufs[e.buf]
  if brTransfer notin e.rights: return beNoRight
  if e.role == hrTransit: return beOk          # forwarding keeps its inner mode
  case mode
  of tmMove:
    if b.state == bsLent: return beNotOwned    # covers borrowers too
  of tmLend:
    if e.role != hrOwner or b.state != bsOwned or b.owner != t: return beNotOwned
  of tmShare:
    if b.state != bsSealed: return beNotOwned
  of tmTransit: return beNoRight               # transit is how it's received, not sent
  beOk

proc applySend(s: var BufStore; t: TaskId; slot: int; mode: TransferMode) =
  ## Sender-side effect of a send that passed sendCheck.
  let e = s.tasks[t].handles[slot]
  let b = e.buf
  case mode
  of tmMove:
    if s.bufs[b].state == bsOwned: s.bufs[b].owner = -1   # in transit
    s.dropHandle(t, slot)                     # its reference rides the flight
  of tmLend:
    s.bufs[b].state = bsLent                  # lender keeps a no-access handle
    s.bufs[b].borrower = -1
    s.bufs[b].lendWrite = brWrite in e.rights
    inc s.bufs[b].refs                        # the flight's reference
  of tmShare:
    inc s.bufs[b].refs
  of tmTransit: discard

proc bufSend*(s: var BufStore; t: TaskId; h: BufHandle; mode: TransferMode;
              flight: var InFlightId): BufError =
  ## Put handle h into a message. Like Zircon, the handle leaves the sender
  ## now; the flight holds the reference until deliver or cancel.
  flight = -1
  let slot = s.lookup(t, h)
  if slot < 0: return beBadHandle
  let e = s.tasks[t].handles[slot]
  let err = s.sendCheck(e, t, mode)
  if err != beOk: return err
  let effMode = if e.role == hrTransit: e.innerMode else: mode
  let rights = if effMode == tmShare: {brRead, brMap, brTransfer} else: e.rights
  flight = s.newFlight(InFlight(buf: e.buf, mode: effMode, rights: rights, sender: t))
  if flight < 0: return beRingFull
  if e.role == hrTransit:
    s.dropHandle(t, slot)                     # forwarded: the flight carries it
  else:
    s.applySend(t, slot, effMode)
  beOk

proc settle(s: var BufStore; f: InFlight; t: TaskId): BufHandle =
  ## Deliver flight f to task t as an ordinary (non-transit) handle.
  let b = f.buf
  case f.mode
  of tmMove:
    if s.bufs[b].state == bsSealed:
      return s.addHandle(t, b, hrReader, f.rights - {brWrite})
    s.bufs[b].owner = t
    s.uncharge(b)
    s.charge(b, t)                            # budgets follow ownership
    s.addHandle(t, b, hrOwner, f.rights)
  of tmLend:
    s.bufs[b].borrower = t
    s.addHandle(t, b, hrBorrower, f.rights)
  of tmShare, tmTransit:
    s.addHandle(t, b, hrReader, f.rights - {brWrite})

proc bufDeliver*(s: var BufStore; flight: InFlightId; t: TaskId; asTransit: bool;
                 h: var BufHandle): BufError =
  ## Hand the flight's handle to receiver t. asTransit: t (the dispatcher)
  ## may only forward it. Fails if t has no room or (move) no budget; the
  ## flight then stays pending for a retry or bufCancel.
  h = NoHandle
  if flight notin 0 ..< MaxInFlight or not s.flights[flight].used: return beBadHandle
  if t notin 0 ..< MaxTasks or not s.tasks[t].attached: return beBadHandle
  if not s.hasFreeHandle(t): return beTooManyHandles
  let f = s.flights[flight]
  if asTransit:
    h = s.addHandle(t, f.buf, hrTransit, f.rights, f.mode)
  else:
    if f.mode == tmMove and s.bufs[f.buf].state == bsOwned and
       s.budgetLeft(t) < s.cost(f.buf): return beNoBudget
    h = s.settle(f, t)
  s.flights[flight].used = false              # its reference is now h's
  beOk

proc dropFlightRef(s: var BufStore; b: int; mode: TransferMode) =
  ## A reference that will never be delivered goes away.
  if mode == tmLend: s.endLend(b)
  s.unref(b)

proc bufCancel*(s: var BufStore; flight: InFlightId): BufError =
  ## The message was dropped: a move is lost (freed if unreferenced), a lend
  ## returns to the lender, a share releases its reference.
  if flight notin 0 ..< MaxInFlight or not s.flights[flight].used: return beBadHandle
  let f = s.flights[flight]
  s.flights[flight].used = false
  s.dropFlightRef(f.buf, f.mode)
  beOk

# ── return / close / exit ────────────────────────────────────────────────────

proc closeSlot(s: var BufStore; t: TaskId; slot: int) =
  let e = s.tasks[t].handles[slot]
  let b = e.buf
  s.dropHandle(t, slot)
  case e.role
  of hrBorrower:
    if s.bufs[b].state == bsLent and s.bufs[b].borrower == t: s.endLend(b)
  of hrOwner:
    if s.bufs[b].state == bsOwned: s.bufs[b].owner = -1
    # lent: the lender relinquishes; the lend's end drops the last reference
  of hrTransit:
    if e.innerMode == tmLend: s.endLend(b)
  of hrReader: discard
  s.unref(b)

proc bufReturn*(s: var BufStore; t: TaskId; h: BufHandle): BufError =
  ## Borrower ends a lend: its handle goes, the lender has sole access again.
  let slot = s.lookup(t, h)
  if slot < 0: return beBadHandle
  if s.tasks[t].handles[slot].role != hrBorrower: return beNotOwned
  s.closeSlot(t, slot)
  beOk

proc bufClose*(s: var BufStore; t: TaskId; h: BufHandle): BufError =
  let slot = s.lookup(t, h)
  if slot < 0: return beBadHandle
  s.closeSlot(t, slot)
  beOk

proc taskExit*(s: var BufStore; t: TaskId) =
  ## Close everything t holds (lends it borrowed return; buffers it lent are
  ## relinquished), orphan the charges of buffers others still reference.
  if t notin 0 ..< MaxTasks or not s.tasks[t].attached: return
  for slot in 0 ..< MaxHandles:
    if s.tasks[t].handles[slot].used: s.closeSlot(t, slot)
  for b in 0 ..< MaxBufs:
    if s.bufs[b].live and s.bufs[b].chargedTo == t: s.uncharge(b)
  s.tasks[t].attached = false

# ── invariants (the oracle for property tests; cheap enough for debug builds) ─

proc liveBuffers*(s: BufStore): int =
  for b in s.bufs:
    if b.live: inc result

proc inFlight*(s: BufStore): int =
  for f in s.flights:
    if f.used: inc result

proc checkInvariants*(s: BufStore): string =
  ## "" if every invariant holds, else the first violation.
  var refs: array[MaxBufs, int]
  var accessors: array[MaxBufs, int]
  var writers: array[MaxBufs, int]
  var charged: array[MaxTasks, int]
  var ownerHandleOf: array[MaxBufs, int]       # task holding the hrOwner handle, -1
  var lendHolders: array[MaxBufs, int]         # borrower / lend-in-transit / lend flight
  for b in 0 ..< MaxBufs: ownerHandleOf[b] = -1
  for t in 0 ..< MaxTasks:
    if not s.tasks[t].attached: continue
    for i in 0 ..< MaxHandles:
      let e = s.tasks[t].handles[i]
      if not e.used: continue
      if not s.bufs[e.buf].live: return "I3: handle names a freed buffer"
      if e.role == hrOwner: ownerHandleOf[e.buf] = t
      if e.role == hrBorrower or e.role == hrTransit and e.innerMode == tmLend:
        inc lendHolders[e.buf]
      if s.bufs[e.buf].state == bsSealed and brWrite in e.rights:
        return "I2: a sealed buffer's handle carries the write right"
      inc refs[e.buf]
      let a = s.access(t, encode(i, e.gen))
      if a != acNone: inc accessors[e.buf]
      if a == acReadWrite: inc writers[e.buf]
  for f in s.flights:
    if f.used:
      if not s.bufs[f.buf].live: return "I3: flight names a freed buffer"
      inc refs[f.buf]
      if f.mode == tmLend: inc lendHolders[f.buf]
  for b in 0 ..< MaxBufs:
    let x = s.bufs[b]
    if not x.live:
      if refs[b] != 0: return "I3: references to a dead buffer"
      continue
    if refs[b] != x.refs: return "I3: refcount drift"
    if x.refs <= 0: return "I3: live buffer with no reference (leak)"
    if x.state != bsSealed and accessors[b] > 1: return "I1: two tasks can access an owned buffer"
    if x.state == bsSealed and writers[b] > 0: return "I2: a sealed buffer is writable"
    if (x.state == bsLent) != (lendHolders[b] == 1) or lendHolders[b] > 1:
      return "lend: a lent buffer must have exactly one lend holder (else the lender is locked out)"
    if x.state == bsOwned and x.owner != ownerHandleOf[b]:
      return "state: owner field disagrees with the owner handle"   # enforcement reads it
    if x.chargedTo >= 0: charged[x.chargedTo] += s.cost(b)
  var blocks = 0
  for b in 0 ..< MaxBufs:
    if s.bufs[b].live:
      blocks += s.bufs[b].run.count
      for o in b + 1 ..< MaxBufs:
        if s.bufs[o].live:
          let x = s.bufs[b].run
          let y = s.bufs[o].run
          if x.first < y.first + y.count and y.first < x.first + x.count:
            return "arena: two buffers share a block"
  if blocks != s.arena.blocks - s.arena.freeBlocks: return "arena: blocks leaked or double-counted"
  for t in 0 ..< MaxTasks:
    if s.tasks[t].attached:
      if charged[t] != s.tasks[t].used: return "budget: charges drift"
      if s.tasks[t].used > s.tasks[t].budget: return "budget: over budget"
  ""

# ── descriptor helpers (rings name a producer's own handle by slot) ──────────

func handleSlot*(h: BufHandle): uint16 =
  ## The per-task slot of a handle — what a producer puts in BufRef.handleIdx.
  uint16((uint32(h) and 0xFFFF) - 1)

proc handleAt*(s: BufStore; t: TaskId; slot: int): BufHandle =
  ## Task t's current handle in `slot`, or NoHandle. Only t's own table is
  ## consulted, so a descriptor can never name another task's buffer.
  if t notin 0 ..< MaxTasks or not s.tasks[t].attached: return NoHandle
  if slot notin 0 ..< MaxHandles or not s.tasks[t].handles[slot].used: return NoHandle
  encode(slot, s.tasks[t].handles[slot].gen)

# ── enforcement queries ───────────────────────────────────────────────────────

proc isAttached*(s: BufStore; t: TaskId): bool =
  t in 0 ..< MaxTasks and s.tasks[t].attached

proc blockAccess*(s: BufStore; t: TaskId; acc: var array[MaxBlocks, Access]) =
  ## Per arena block, the access task t has right now — what the enforcement
  ## layer turns into page rights at switch-in.
  for i in 0 ..< MaxBlocks: acc[i] = acNone
  if not s.isAttached(t): return
  for slot in 0 ..< MaxHandles:
    let e = s.tasks[t].handles[slot]
    if not e.used: continue
    let a = s.access(t, encode(slot, e.gen))
    if a == acNone: continue
    let r = s.bufs[e.buf].run
    for b in r.first ..< r.first + r.count:
      if a > acc[b]: acc[b] = a
