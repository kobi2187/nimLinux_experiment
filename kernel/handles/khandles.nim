# SPDX-License-Identifier: GPL-2.0
## The kernel's handle space and channel store (ipc/handles), and the syscalls over them.
##
## One `HandleSpace` and one `ChannelStore` for the whole kernel; a task's table is indexed by its
## process-table slot and attached lazily on first use. A task's death closes its handles and
## releases what that frees (kernel/abi/task_cleanup.nim calls khReleasePid).
##
## Error codes are `-ord(ChResult)` (ipc/handles/channel.nim): 0 is success, -1 is a bad
## argument or handle (the syscall gate's generic refusal means the same).
import ../../ipc/handles/handle_table
import ../../ipc/handles/channel
import ../process_table
import ../../core/log
import ../../drivers/pit
import ../../arch/x86_64/cpu_primitives

const WaitMax* = 8                  ## handles one wait can cover

var
  gHs*: HandleSpace
  gCh*: ChannelStore
  gWaitN: array[HsMaxTasks, int]                    ## handles each blocked task is waiting on
  gWaitEnds: array[HsMaxTasks, array[WaitMax, int32]]

proc onEndReady(endIdx: int) {.nimcall.} =
  ## A message was queued for an end, or its peer closed: wake the tasks waiting on it.
  let fl = disableInterrupts()
  for t in 0 ..< HsMaxTasks:
    for k in 0 ..< gWaitN[t]:
      if gWaitEnds[t][k] == int32(endIdx):
        procWake(t)
        break
  restoreInterrupts(fl)

proc khInit*() =
  hsInit(gHs)
  chInit(gCh)
  chSetReadyHook(onEndReady)

proc khMe*(): int =
  ## The calling task's slot (its table), attached on first use; -1 when no task is current.
  let t = int(procTable.current)
  if t < 0 or t >= HsMaxTasks: return -1
  discard hsAttach(gHs, t)
  t

proc khReleasePid*(pid: uint32) =
  ## Task exit, kill or fault: close every handle the task holds and release what that frees.
  for slot in 0 ..< process_table.MaxTasks:
    if procTable.tasks[slot].used and procTable.tasks[slot].pid == pid:
      gWaitN[slot] = 0
      chCloseAll(gHs, gCh, slot)

proc khGrant*(fromTask: int; h: Handle; childSlot: int; rights: Rights): bool =
  ## Spawn-time grant: move handle h from the spawner's table into the (fresh) table of the child.
  ## The first grant to a new task lands on the bootstrap value. Call with interrupts off, between
  ## creating the task and letting it run.
  if fromTask < 0 or childSlot < 0 or childSlot >= HsMaxTasks: return false
  discard hsAttach(gHs, childSlot)
  var f: Flight
  if hsTransferOut(gHs, fromTask, h, rights, f) != heOk: return false
  var nh: Handle
  if hsTransferIn(gHs, childSlot, f, nh) != heOk:
    var d: Destroyed
    hsDropFlight(gHs, f, d)
    return false
  if nh != BootstrapHandle:
    klog(llWarn, "khGrant: first handle is not the bootstrap value")
  true

# ── syscalls ──────────────────────────────────────────────────────────────────

type
  ChanPairReq {.packed.} = object
    size, rights0, rights1, pad: uint32
    badge0, badge1: uint64
    h0, h1: uint32

  SendEnt {.packed.} = object
    h, rights: uint32

  SendListReq {.packed.} = object
    n: uint32
    ent: array[ChMaxFlights, SendEnt]

  ChanInfo {.packed.} = object
    n: int32
    nGot: uint32
    badge: uint64
    got: array[ChMaxFlights, uint32]

template code(r: ChResult): int = -ord(r)

proc abiChanPair*(req: pointer): int {.nimcall.} =
  ## New channel; the caller gets both ends. The badge of an end's handle is what the OTHER side
  ## sees on every message written through it. Rights are limited to what a channel end has.
  let t = khMe()
  if t < 0: return code(crBadTask)
  var q = cast[ptr ChanPairReq](req)[]
  let mask = rtChannelDefault
  var r0 = Rights(q.rights0) and mask
  var r1 = Rights(q.rights1) and mask
  if r0 == rtNone: r0 = rtChannelDefault
  if r1 == rtNone: r1 = rtChannelDefault
  var a, b: Handle
  let r = chCreate(gHs, gCh, t, r0, r1, q.badge0, q.badge1, a, b)
  if r != crOk: return code(r)
  let o = cast[ptr ChanPairReq](req)
  o.h0 = uint32(a); o.h1 = uint32(b)
  0

proc abiChanWrite*(h: uint32; data: pointer; len: int; send: pointer): int {.nimcall.} =
  let t = khMe()
  if t < 0: return code(crBadTask)
  if len < 0 or len > ChMsgBytes: return code(crTooBig)
  var sl: array[ChMaxFlights, SendHandle]
  var n = 0
  if send != nil:
    let q = cast[ptr SendListReq](send)[]
    if q.n > uint32(ChMaxFlights): return code(crTooManyHandles)
    n = int(q.n)
    for i in 0 ..< n: sl[i] = SendHandle(h: Handle(q.ent[i].h), rights: Rights(q.ent[i].rights))
  let bytes = cast[ptr UncheckedArray[byte]](data)
  code(chWrite(gHs, gCh, t, Handle(h), toOpenArray(bytes, 0, len - 1), toOpenArray(sl, 0, n - 1)))

proc abiChanRead*(h: uint32; buf: pointer; cap: int; info: pointer): int {.nimcall.} =
  let t = khMe()
  if t < 0: return code(crBadTask)
  if cap < 0: return code(crTooBig)
  let bytes = cast[ptr UncheckedArray[byte]](buf)
  var n, nGot: int
  var badge: uint64
  var got: array[ChMaxFlights, Handle]
  let r = chRead(gHs, gCh, t, Handle(h), toOpenArray(bytes, 0, cap - 1), n, badge, got, nGot)
  if info != nil:
    let o = cast[ptr ChanInfo](info)
    o.n = int32(n); o.nGot = uint32(nGot); o.badge = badge
    for i in 0 ..< nGot: o.got[i] = uint32(got[i])
  code(r)

proc abiHandleClose*(h: uint32): int {.nimcall.} =
  let t = khMe()
  if t < 0: return code(crBadTask)
  code(chClose(gHs, gCh, t, Handle(h)))

proc abiHandleDup*(h: uint32; rights: uint32): int {.nimcall.} =
  ## A second handle to the same object with rights that are a subset of the original's.
  let t = khMe()
  if t < 0: return code(crBadTask)
  var nh: Handle
  case hsDuplicate(gHs, t, Handle(h), Rights(rights), nh)
  of heOk: int(uint32(nh))
  of heWidens: code(crWidens)
  of heNoRight: code(crNoRight)
  of heTableFull: code(crTableFull)
  else: code(crBadHandle)

proc abiChanStatus*(h: uint32): int {.nimcall.} =
  ## bit 0: a message can be read now; bit 1: the peer has closed.
  let t = khMe()
  if t < 0: return code(crBadTask)
  var o: ObjId
  var b: uint64
  if hsLookup(gHs, t, Handle(h), okChannelEnd, rtNone, o, b) != heOk: return code(crBadHandle)
  (if chReadable(gHs, gCh, t, Handle(h)): 1 else: 0) or (if chPeerClosed(gHs, gCh, t, Handle(h)): 2 else: 0)

# ── wait (mechanism S4) ───────────────────────────────────────────────────────

type WaitItem {.packed.} = object
  h, ready: uint32

proc abiWait*(items: pointer; n: int; ticks: uint32): int {.nimcall.} =
  ## Block until one of up to WaitMax channel ends is readable or its peer has closed, or the
  ## timeout (PIT ticks; 0xFFFFFFFF = forever) passes. Each item's `ready` gets bit 0 (readable) and
  ## bit 1 (peer closed). Returns how many items are ready (0 = timed out) or a negative error.
  ## A blocked task is not scheduled and costs nothing; a channel write or close wakes it. It then
  ## runs at the next scheduling point (a tick, today): sub-tick wake latency needs a finer timer.
  let t = khMe()
  if t < 0: return code(crBadTask)
  if n < 1 or n > WaitMax: return code(crBadHandle)
  let it = cast[ptr UncheckedArray[WaitItem]](items)
  let forever = ticks == 0xFFFFFFFF'u32
  let deadline = pitTicks() + uint64(ticks)
  var ends: array[WaitMax, int32]
  for i in 0 ..< n:
    var o: ObjId
    var b: uint64
    let h = it[i].h                          # the caller's memory: read it once
    if hsLookup(gHs, t, Handle(h), okChannelEnd, rtWait, o, b) != heOk: return code(crBadHandle)
    ends[i] = hsObjPayload(gHs, o)
  while true:
    var ready = 0
    for i in 0 ..< n:
      let h = Handle(it[i].h)
      var bits = 0'u32
      if chReadable(gHs, gCh, t, h): bits = bits or 1
      if chPeerClosed(gHs, gCh, t, h): bits = bits or 2
      it[i].ready = bits
      if bits != 0: inc ready
    if ready > 0: return ready
    if not forever and pitTicks() >= deadline: return 0
    gWaitN[t] = n
    for i in 0 ..< n: gWaitEnds[t][i] = ends[i]
    procSleepUntil(t, if forever: 0'u64 else: deadline)   # wakeAt = 0: blocked until woken
    while procTable.tasks[t].state == ptsBlocked:
      sti(); hlt(); cli()                    # syscalls run with IF=0: let the tick switch us away
    gWaitN[t] = 0
