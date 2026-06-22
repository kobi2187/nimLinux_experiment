# SPDX-License-Identifier: GPL-2.0
## Monolithic Kernel Model
##
## Wires up the global `scheduler` and `ipc` vtables using direct in-kernel
## function calls. No privilege-level separation — everything runs in ring 0.
##
## Scheduler: three-class (Realtime/Server/App) ring scheduler backed by
##            the global ProcessTable (kernel/process_table.nim).
## IPC:       ring-buffer channels (MaxChannels slots, ChannelBufSize=8 msgs).

import ../../core/types
import ../../core/log
import ../../kernel/config
import ../../kernel/traits/scheduler as schedTrait
import ../../kernel/traits/ipc as ipcTrait
import ../../kernel/abi/nimix_abi as abiModule
import ../../kernel/abi/nimix_abi_impl
import ../../kernel/process_table

# Re-export the trait types so callers can use them without further imports
export schedTrait
export ipcTrait

# ═══════════════════════════════════════════════════════════════════════════
# Constants
# ═══════════════════════════════════════════════════════════════════════════

const
  ChannelBufSize* = 8   ## Ring-buffer capacity per IPC channel

# ═══════════════════════════════════════════════════════════════════════════
# IPC Channel Ring Buffer
# ═══════════════════════════════════════════════════════════════════════════

type
  Channel = object
    isOpen: bool
    head:   uint32   ## read index
    tail:   uint32   ## write index
    count:  uint32
    buf:    array[ChannelBufSize, Message]

var
  channels: array[MaxChannels, Channel]

# ═══════════════════════════════════════════════════════════════════════════
# Scheduler Implementation — Three-Class Ring Scheduler
# ═══════════════════════════════════════════════════════════════════════════

proc monoSpawn(entry: schedTrait.TaskProc; priority: TaskPriority): Result[TaskId, SchedulerError] {.nimcall.} =
  let slot = procSpawn("task", entry, tcApp, uint8(priority))
  if slot < 0:
    return Result[TaskId, SchedulerError](isOk: false, error: seOutOfSlots)
  Result[TaskId, SchedulerError](isOk: true, value: TaskId(uint32(slot)))

proc monoSpawnNamed(name: cstring; entry: schedTrait.TaskProc; priority: TaskPriority;
                    cls: uint8): Result[TaskId, SchedulerError] {.nimcall.} =
  let taskClass = if cls <= 2: TaskClass(cls) else: tcApp
  let slot = procSpawn(name, entry, taskClass, uint8(priority))
  if slot < 0:
    return Result[TaskId, SchedulerError](isOk: false, error: seOutOfSlots)
  Result[TaskId, SchedulerError](isOk: true, value: TaskId(uint32(slot)))

proc monoYield() {.nimcall.} =
  let next = procPickNext(procTable)
  if next >= 0:
    procTable.current = next
    procTable.tasks[next].state = ptsRunning
    inc procTable.tasks[next].switches
    inc procTable.stats.totalSwitches

proc monoBlock(id: TaskId): Result[void, SchedulerError] {.nimcall.} =
  let idx = int(uint32(id))
  if idx >= process_table.MaxTasks or not procTable.tasks[idx].used:
    return Result[void, SchedulerError](isOk: false, error: seInvalidTask)
  if procTable.tasks[idx].state == ptsReady:
    process_table.ringRemove(procTable, int16(idx), int(procTable.tasks[idx].class))
  procTable.tasks[idx].state = ptsBlocked
  Result[void, SchedulerError](isOk: true)

proc monoWake(id: TaskId): Result[void, SchedulerError] {.nimcall.} =
  let idx = int(uint32(id))
  if idx >= process_table.MaxTasks or not procTable.tasks[idx].used:
    return Result[void, SchedulerError](isOk: false, error: seInvalidTask)
  if procTable.tasks[idx].state != ptsBlocked:
    return Result[void, SchedulerError](isOk: false, error: seNotBlocked)
  procTable.tasks[idx].state = ptsReady
  process_table.ringInsertTail(procTable, int16(idx), int(procTable.tasks[idx].class))
  Result[void, SchedulerError](isOk: true)

proc monoCurrent(): TaskId {.nimcall.} =
  TaskId(uint32(if procTable.current >= 0: procTable.current else: 0))

proc monoExit() {.nimcall.} =
  let slot = procTable.current
  if slot >= 0:
    discard procKill(slot)
  monoYield()

proc monoKill(id: TaskId): Result[void, SchedulerError] {.nimcall.} =
  let slot = procFindPid(uint32(id))
  if slot < 0:
    return Result[void, SchedulerError](isOk: false, error: seInvalidTask)
  discard procKill(slot)
  Result[void, SchedulerError](isOk: true)

# ═══════════════════════════════════════════════════════════════════════════
# IPC Implementation — Direct Ring-Buffer Copy
# ═══════════════════════════════════════════════════════════════════════════

proc monoSend(ch: ChannelId, msg: ptr Message): IpcResult {.nimcall.} =
  let idx = uint32(ch)
  if idx >= uint32(MaxChannels) or not channels[idx].isOpen:
    return mrInvalid
  if channels[idx].count >= uint32(ChannelBufSize):
    return mrFull
  channels[idx].buf[channels[idx].tail] = msg[]
  channels[idx].tail = (channels[idx].tail + 1) mod uint32(ChannelBufSize)
  inc channels[idx].count
  mrOk

proc monoRecv(ch: ChannelId, msg: ptr Message): IpcResult {.nimcall.} =
  let idx = uint32(ch)
  if idx >= uint32(MaxChannels) or not channels[idx].isOpen:
    return mrInvalid
  if channels[idx].count == 0:
    return mrEmpty
  msg[] = channels[idx].buf[channels[idx].head]
  channels[idx].head = (channels[idx].head + 1) mod uint32(ChannelBufSize)
  dec channels[idx].count
  mrOk

proc monoTryRecv(ch: ChannelId, msg: ptr Message): IpcResult {.nimcall.} =
  monoRecv(ch, msg)

proc monoOpen(): Result[ChannelId, IpcResult] {.nimcall.} =
  for i in 0 ..< MaxChannels:
    if not channels[i].isOpen:
      channels[i].isOpen = true
      channels[i].head   = 0
      channels[i].tail   = 0
      channels[i].count  = 0
      return Result[ChannelId, IpcResult](isOk: true, value: ChannelId(uint32(i)))
  Result[ChannelId, IpcResult](isOk: false, error: mrInvalid)

proc monoClose(ch: ChannelId): IpcResult {.nimcall.} =
  let idx = uint32(ch)
  if idx >= uint32(MaxChannels) or not channels[idx].isOpen:
    return mrInvalid
  channels[idx].isOpen = false
  channels[idx].head   = 0
  channels[idx].tail   = 0
  channels[idx].count  = 0
  mrOk

# ═══════════════════════════════════════════════════════════════════════════
# Init — Wire Up Global VTables
# ═══════════════════════════════════════════════════════════════════════════

proc initMonolithicModel*() =
  ## Populate the global scheduler and ipc vtables.
  ## Must be called once during kernel init before any task or IPC operations.

  # Initialise process table (three-class ring scheduler)
  procTableInit()

  # Zero out channel table
  for i in 0 ..< MaxChannels:
    channels[i].isOpen = false
    channels[i].head   = 0
    channels[i].tail   = 0
    channels[i].count  = 0

  # Wire scheduler vtable
  var sv: SchedulerVTable
  sv.spawn       = monoSpawn
  sv.spawnNamed  = monoSpawnNamed
  sv.`yield`     = monoYield
  sv.blockTask   = monoBlock
  sv.wake        = monoWake
  sv.current     = monoCurrent
  sv.exit        = monoExit
  sv.kill        = monoKill
  schedTrait.scheduler = sv

  # Wire IPC vtable
  ipcTrait.ipc.send    = monoSend
  ipcTrait.ipc.recv    = monoRecv
  ipcTrait.ipc.tryRecv = monoTryRecv
  ipcTrait.ipc.open    = monoOpen
  ipcTrait.ipc.close   = monoClose

  # Wire app ABI vtable — monolithic: alloc from global kernel heap
  proc monoAlloc(size: int): pointer {.nimcall.} = cast[pointer](alloc(size))
  proc monoFree(p: pointer; size: int) {.nimcall.} = dealloc(p)
  var av: abiModule.NimixAbiVTable
  av.allocRegion    = monoAlloc
  av.freeRegion     = monoFree
  av.write          = abiWrite
  av.exit           = abiExit
  av.chanSend       = abiChanSend
  av.chanRecv       = abiChanRecv
  av.eventPublish   = abiEventPublish
  av.eventSubscribe = abiEventSubscribe
  av.eventPoll      = abiEventPoll
  abiModule.nimixAbi = av
