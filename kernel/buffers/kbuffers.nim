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
  gApplied: array[MaxBlocks, Access]      ## rights currently in the PD entries
  gReady: bool

proc invlpg(va: uint64) {.inline.} =
  {.emit: ["asm volatile(\"invlpg (%0)\" :: \"r\" (", va, ") : \"memory\");"].}

proc applyRights(t: int) =
  ## Make the arena's page rights say exactly what task t may access.
  if not gReady: return
  var acc: array[MaxBlocks, Access]
  gStore.blockAccess(t, acc)
  let pml4 = cast[ptr PageTable](readCr3() and AddrMask)
  for i in 0 ..< gArenaBlocks:
    if acc[i] != gApplied[i]:
      let va = ArenaBase + uint64(i) * uint64(BlockSize)
      if setBlockRights(pml4, va, acc[i] != acNone, acc[i] == acReadWrite): invlpg(va)
      gApplied[i] = acc[i]

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
  let first = int((p - ArenaBase) div uint64(BlockSize))
  let last = int((p + n - 1 - ArenaBase) div uint64(BlockSize))
  if last >= gArenaBlocks: return false
  for i in first .. last:
    if write:
      if gApplied[i] != acReadWrite: return false
    elif gApplied[i] == acNone: return false
  true

proc finish(e: BufError): int =
  ## Every state change of the caller takes effect before it runs again.
  applyRights(int(procTable.current))
  if e == beOk: 0 else: err(e)

proc abiBufClose*(h: uint32): int {.nimcall.} = finish(gStore.bufClose(me(), BufHandle(h)))
proc abiBufSeal*(h: uint32): int {.nimcall.} = finish(gStore.bufSeal(me(), BufHandle(h)))
proc abiBufReturn*(h: uint32): int {.nimcall.} = finish(gStore.bufReturn(me(), BufHandle(h)))

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
