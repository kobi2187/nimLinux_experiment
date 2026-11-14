# SPDX-License-Identifier: GPL-2.0
## Kernel glue for ipc/buffers (Stage A, ring-3 models).
##
## Owns the global BufStore over the arena window (mm/memory_windows) and
## ENFORCES it: arena blocks are supervisor-only by default; on every switch
## to a task — and right after each buffer syscall the running task makes —
## the PD entries of the arena are set to exactly what that task may access
## (User for any access, RW only for write). A pointer kept after a move, or
## a write to a sealed buffer, therefore faults, and the user-fault policy
## kills only that task.
##
## Task identity: the process-table slot. A task is attached to the store on
## its first buffer call and detached by task cleanup (exit / kill / fault).

import ../../ipc/buffers/types
import ../../ipc/buffers/state
import ../../ipc/server_chan
import ../../mm/region_allocator
import ../../mm/memory_windows
import ../../mm/user_window
import ../../mm/addr_space
import ../space/kspace
import ../../kernel/process_table
import ../../kernel/cap/capability as cap
import ../../arch/x86_64/cpu_primitives
import ../../core/log
import ../abi/user_args

const DefaultBudget = 16 * BlockSize      ## 32 MB of arena per task

type
  BufMsgHandles* = object
    ## Handles riding a message, as passed across the syscall boundary (the
    ## gate has 4 argument registers). In: n, handle[i], mode[i] (TransferMode
    ## ordinal). Out (recv): n, handle[i].
    n*: uint32
    handle*: array[MaxMsgFlights, uint32]
    mode*: array[MaxMsgFlights, uint32]

static: doAssert sizeof(BufMsgHandles) == BufMsgHandlesBytes,
  "kernel/abi/user_args.nim checks BufMsgHandles pointers by this size"

var
  gStore: BufStore
  gApplied: array[MaxRegions, array[MaxBlocks, Access]]   ## rights in each space's PD entries
  gReady: bool

proc invlpg(va: uint64) {.inline.} =
  {.emit: ["asm volatile(\"invlpg (%0)\" :: \"r\" (", va, ") : \"memory\");"].}

var
  gAppliedSerial: array[MaxRegions, uint64]        ## which incarnation of a space gApplied describes

proc applyRights(t: int) =
  ## Make task t's OWN page tables say exactly what t may access in the arena. Tasks have separate
  ## tables, so a block granted to one is simply closed in all the others: there is nothing shared to
  ## rewrite at a context switch, and a task that is not running keeps its tables until it is.
  if not gReady: return
  let sp = ksOfTask(t)
  if sp == nil: return                              # a kernel task: it sees the arena as the kernel
  let r = int(procTable.tasks[t].regionSlot)
  if gAppliedSerial[r] != ksSerial(r):              # a new space starts closed: forget what the last one had
    for i in 0 ..< MaxBlocks: gApplied[r][i] = acNone
    gAppliedSerial[r] = ksSerial(r)
  var acc: array[MaxBlocks, Access]
  gStore.blockAccess(t, acc)
  let live = readCr3() == spaceRoot(sp)
  for i in 0 ..< gArenaBlocks:
    if acc[i] != gApplied[r][i]:
      let va = ArenaBase + uint64(i) * uint64(BlockSize)
      if spaceSetBlock(sp, va, acc[i] != acNone, acc[i] == acReadWrite) and live: invlpg(va)
      gApplied[r][i] = acc[i]

proc onSwitch(next: int) {.nimcall.} = applyRights(next)

proc cancelFlights(m: var ServerMsg) {.nimcall.} =
  for i in 0 ..< int(m.nFlights): discard gStore.bufCancel(m.flights[i])

proc me(): int =
  ## The calling task, attached on first use.
  result = int(procTable.current)
  if not gStore.isAttached(result): discard gStore.taskAttach(result, DefaultBudget)

proc kbufInit*() =
  gStore.initStore(ArenaBase, BlockSize, gArenaBlocks)
  onTaskSwitch = onSwitch
  onMsgDropped = cancelFlights
  gReady = true
  klogInt(llInfo, "buffers: arena ready, blocks=", int64(gArenaBlocks))

proc kbufReleasePid*(pid: uint32) =
  ## Task cleanup: close everything the task holds (lends return, moves in
  ## flight stay in their messages) and re-apply the running task's rights.
  for slot in 0 ..< process_table.MaxTasks:
    if procTable.tasks[slot].used and procTable.tasks[slot].pid == pid:
      gStore.taskExit(slot)
  applyRights(int(procTable.current))

# ── syscalls (all act for the calling task; errors are -ord(BufError)) ──────

template err(e: BufError): int = -ord(e)

proc abiBufCreate*(size: int): int {.nimcall.} =
  var h: BufHandle
  let e = gStore.bufCreate(me(), size, h)
  if e != beOk: return err(e)
  int(uint32(h))

proc abiBufMap*(h: uint32): pointer {.nimcall.} =
  ## Address of the buffer, mapped with the caller's rights; nil if none.
  let t = me()
  var a: uint64
  var w: bool
  if gStore.bufMapAddr(t, BufHandle(h), a, w) != beOk: return nil
  applyRights(t)
  cast[pointer](a)

proc kbufReadable*(h: uint32; base: var uint64; size: var int): bool =
  ## For kernel services that read the caller's memory on its behalf (display
  ## present): the buffer's address and size, only if the CALLER may read it right
  ## now. A buffer it moved or lent away, or a stale or foreign handle, gives false.
  let t = me()
  var w: bool
  if gStore.bufMapAddr(t, BufHandle(h), base, w) != beOk: return false
  if gStore.bufSize(t, BufHandle(h), size) != beOk: return false
  applyRights(t)
  true

proc kbufAccessible*(p, n: uint64; write: bool): bool =
  ## May the RUNNING task read (write) arena bytes [p, p+n)? Per block, from the rights the
  ## page tables currently carry for it. The kernel dereferences syscall arguments with supervisor
  ## rights, which ignore those page rights, so the syscall gate asks here first.
  if n == 0: return true
  if not gReady or p < ArenaBase: return false
  let cur = int(procTable.current)
  if cur < 0 or procTable.tasks[cur].regionSlot < 0: return false
  let r = int(procTable.tasks[cur].regionSlot)
  let first = int((p - ArenaBase) div uint64(BlockSize))
  let last = int((p + n - 1 - ArenaBase) div uint64(BlockSize))
  if last >= gArenaBlocks: return false
  for i in first .. last:
    if write:
      if gApplied[r][i] != acReadWrite: return false
    elif gApplied[r][i] == acNone: return false
  true

proc finish(e: BufError): int =
  ## Every state change of the caller takes effect before it runs again.
  applyRights(int(procTable.current))
  if e == beOk: 0 else: err(e)

proc abiBufClose*(h: uint32): int {.nimcall.} = finish(gStore.bufClose(me(), BufHandle(h)))
proc abiBufSeal*(h: uint32): int {.nimcall.} = finish(gStore.bufSeal(me(), BufHandle(h)))
proc abiBufReturn*(h: uint32): int {.nimcall.} = finish(gStore.bufReturn(me(), BufHandle(h)))

# ── buffers inside channel messages (ipc/handles/channel foreign flights) ───────
# A buffer handle sent through a channel becomes a transfer in flight inside the store; the message
# carries only its id. Error codes of this layer are -(20 + ord(BufError)) so they never collide with
# the channel's (-1 .. -15).

const
  BufKindMove* = 1'u32
  BufKindLend* = 2'u32
  BufKindShare* = 3'u32

template bufErr(e: BufError): int = -(20 + ord(e))

proc kindMode(kind: uint32; mode: var TransferMode): bool =
  case kind
  of BufKindMove: mode = tmMove
  of BufKindLend: mode = tmLend
  of BufKindShare: mode = tmShare
  else: return false
  true

proc kbufFlightRoom*(): int = gStore.bufFlightRoom()

proc kbufCanSend*(h: uint32; kind: uint32): int =
  ## 0 if the caller could send buffer handle h this way right now, else the (negative) error.
  var mode: TransferMode
  if not kindMode(kind, mode): return bufErr(beBadHandle)
  let e = gStore.bufCanSend(me(), BufHandle(h), mode)
  if e == beOk: 0 else: bufErr(e)

proc kbufSendFlight*(h: uint32; kind: uint32; id: var int32): int =
  ## Take buffer handle h out of the caller's hands as a transfer in flight. The sender's access
  ## ends now (a lent buffer is not usable by its lender while lent), so its page rights are
  ## re-applied at once.
  id = -1
  var mode: TransferMode
  if not kindMode(kind, mode): return bufErr(beBadHandle)
  let t = me()
  var f: InFlightId
  let e = gStore.bufSend(t, BufHandle(h), mode, f)
  if e != beOk: return bufErr(e)
  id = int32(f)
  applyRights(t)
  0

proc kbufCancelFlight*(id: int32) =
  ## The message was discarded: a move is lost, a lend returns to the lender, a share is released.
  discard gStore.bufCancel(InFlightId(id))
  if procTable.current >= 0: applyRights(int(procTable.current))   # the lender may be running

proc ensureAttached(t: int) =
  if not gStore.isAttached(t): discard gStore.taskAttach(t, DefaultBudget)

proc kbufForeignCanDeliver*(kind: uint8; id: int32; t: int): bool {.nimcall.} =
  if kind != 1: return false
  ensureAttached(t)
  gStore.bufCanDeliver(InFlightId(id), t) == beOk

proc kbufForeignDeliver*(kind: uint8; id: int32; t: int; handle: var uint32): bool {.nimcall.} =
  if kind != 1: return false
  ensureAttached(t)
  var h: BufHandle
  if gStore.bufDeliver(InFlightId(id), t, false, h) != beOk: return false
  handle = uint32(h)
  applyRights(t)                                    # the receiver's own tables now open the block
  true

proc kbufForeignDrop*(kind: uint8; id: int32) {.nimcall.} =
  if kind == 1: kbufCancelFlight(id)

proc abiBufMsgSend*(name: cstring; data: pointer; dataLen: int;
                    hs: ptr BufMsgHandles): int {.nimcall.} =
  ## Post a message to channel `name` carrying n handles. Each handle leaves
  ## the caller now (move/lend/share); if the post fails every transfer is
  ## cancelled. Returns 0, -1 (no such channel / full) or -ord(BufError).
  let ch = serverChanFind(name)
  if ch == nil: return -1
  let n = if hs == nil: 0 else: int(hs.n)
  if n > MaxMsgFlights or dataLen < 0 or dataLen > ServerMsgMaxLen:
    return err(beTooManyHandles)
  let t = me()
  var msg = ServerMsg(len: uint16(dataLen))
  if dataLen > 0: copyMem(addr msg.data[0], data, dataLen)
  for i in 0 ..< n:
    if hs.mode[i] > uint32(ord(tmShare)): return finish(beNoRight)   # tmTransit is not sendable
    var f: InFlightId
    let e = gStore.bufSend(t, BufHandle(hs.handle[i]), TransferMode(hs.mode[i]), f)
    if e != beOk:
      cancelFlights(msg)
      return finish(e)
    msg.flights[i] = int16(f)
    msg.nFlights = uint8(i + 1)
  if not serverChanPost(ch[], msg):
    cancelFlights(msg)
    discard finish(beOk)
    return -1
  finish(beOk)

proc abiBufMsgRecv*(tok: uint64; buf: pointer; bufLen: int;
                    hs: ptr BufMsgHandles): int {.nimcall.} =
  ## Receive on the channel bound to `tok`, taking its handles into the
  ## caller's table. Bytes written, -1 if empty, -3 if `tok` is not valid.
  if not cap.capCheck(CapToken(tok), capIpc): return -3
  let ch = serverChanFindByCap(tok)
  if ch == nil: return -3
  var m = serverChanRecv(ch[])
  if not m.hasValue: return -1
  let t = me()
  var got = 0'u32
  for i in 0 ..< int(m.value.nFlights):
    var h: BufHandle
    if hs != nil and gStore.bufDeliver(m.value.flights[i], t, false, h) == beOk:
      hs.handle[got] = uint32(h)
      inc got
    else:
      discard gStore.bufCancel(m.value.flights[i])   # no room: never duplicated
  if hs != nil: hs.n = got
  discard finish(beOk)
  let k = min(bufLen, int(m.value.len))
  if k > 0: copyMem(buf, addr m.value.data[0], k)
  k
