# SPDX-License-Identifier: GPL-2.0
## Monolithic Kernel Model
##
## Wires up the global `scheduler` and `ipc` vtables using direct in-kernel
## function calls. No privilege-level separation — everything runs in ring 0.
##
## Scheduler: simple round-robin over a fixed task table (MaxTasks slots).
## IPC:       ring-buffer channels (MaxChannels slots, ChannelBufSize=8 msgs).

import ../../core/types
import ../../kernel/config
import ../../kernel/traits/scheduler as schedTrait
import ../../kernel/traits/ipc as ipcTrait

# Re-export the trait types so callers can use them without further imports
export schedTrait
export ipcTrait

# ═══════════════════════════════════════════════════════════════════════════
# Constants
# ═══════════════════════════════════════════════════════════════════════════

const
  ChannelBufSize* = 8   ## Ring-buffer capacity per IPC channel

# ═══════════════════════════════════════════════════════════════════════════
# Task Table
# ═══════════════════════════════════════════════════════════════════════════

type
  TaskEntry = object
    used:     bool
    state:    TaskState
    entry:    TaskProc
    priority: TaskPriority

var
  taskTable:   array[MaxTasks, TaskEntry]
  taskCount:   uint32 = 0
  currentTask: uint32 = 0

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
# Scheduler Implementation — Round-Robin
# ═══════════════════════════════════════════════════════════════════════════

proc monoSpawn(entry: TaskProc, priority: TaskPriority): Result[TaskId, SchedulerError] {.nimcall.} =
  if taskCount >= uint32(MaxTasks):
    return Result[TaskId, SchedulerError](isOk: false, error: seOutOfSlots)
  for i in 0 ..< MaxTasks:
    if not taskTable[i].used:
      taskTable[i].used     = true
      taskTable[i].state    = tsReady
      taskTable[i].entry    = entry
      taskTable[i].priority = priority
      inc taskCount
      return Result[TaskId, SchedulerError](isOk: true, value: TaskId(uint32(i)))
  Result[TaskId, SchedulerError](isOk: false, error: seOutOfSlots)

proc monoYield() {.nimcall.} =
  var next = (currentTask + 1) mod uint32(MaxTasks)
  for _ in 0 ..< MaxTasks:
    if taskTable[next].used and taskTable[next].state == tsReady:
      currentTask = next
      return
    next = (next + 1) mod uint32(MaxTasks)

proc monoBlock(id: TaskId): Result[void, SchedulerError] {.nimcall.} =
  let idx = uint32(id)
  if idx >= uint32(MaxTasks) or not taskTable[idx].used:
    return Result[void, SchedulerError](isOk: false, error: seInvalidTask)
  taskTable[idx].state = tsBlocked
  Result[void, SchedulerError](isOk: true)

proc monoWake(id: TaskId): Result[void, SchedulerError] {.nimcall.} =
  let idx = uint32(id)
  if idx >= uint32(MaxTasks) or not taskTable[idx].used:
    return Result[void, SchedulerError](isOk: false, error: seInvalidTask)
  if taskTable[idx].state != tsBlocked:
    return Result[void, SchedulerError](isOk: false, error: seNotBlocked)
  taskTable[idx].state = tsReady
  Result[void, SchedulerError](isOk: true)

proc monoCurrent(): TaskId {.nimcall.} =
  TaskId(currentTask)

proc monoExit() {.nimcall.} =
  let idx = currentTask
  if taskTable[idx].used:
    taskTable[idx].used  = false
    taskTable[idx].state = tsZombie
    if taskCount > 0:
      dec taskCount
  monoYield()

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

  # Zero out task table
  for i in 0 ..< MaxTasks:
    taskTable[i].used  = false
    taskTable[i].state = tsReady

  # Zero out channel table
  for i in 0 ..< MaxChannels:
    channels[i].isOpen = false
    channels[i].head   = 0
    channels[i].tail   = 0
    channels[i].count  = 0

  taskCount   = 0
  currentTask = 0

  # Wire scheduler vtable — build local copy first to avoid `spawn` keyword
  # ambiguity at the call site (Nim treats `scheduler.spawn` as parallel spawn)
  var sv: SchedulerVTable
  sv.spawn     = monoSpawn
  sv.`yield`   = monoYield
  sv.blockTask = monoBlock
  sv.wake      = monoWake
  sv.current   = monoCurrent
  sv.exit      = monoExit
  schedTrait.scheduler = sv

  # Wire IPC vtable
  ipcTrait.ipc.send    = monoSend
  ipcTrait.ipc.recv    = monoRecv
  ipcTrait.ipc.tryRecv = monoTryRecv
  ipcTrait.ipc.open    = monoOpen
  ipcTrait.ipc.close   = monoClose
