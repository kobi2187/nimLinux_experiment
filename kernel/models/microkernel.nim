# SPDX-License-Identifier: GPL-2.0
## Microkernel Model
##
## Architecture with hardware-enforced isolation between services:
##
## Scheduler: Multi-level priority queue with 4 bands (Critical, High,
##   Normal, Low). Kernel services run at Critical priority; round-robin
##   within each band. This ensures IPC servers are always preferred
##   over application tasks.
##
## IPC: Double-copy via kernel staging buffer. Every message passes
##   through a kernel-owned intermediary — simulating the copy semantics
##   of a real microkernel where the kernel validates and relays messages
##   between isolated address spaces.
##
## Service Registry: Named services register a ChannelId under a
##   human-readable name ("vfs", "kbd"). Clients look up services by
##   name to obtain the ChannelId for communication.
##
## To select: -d:kernelModel=microkernel

import ../../core/types
import ../../kernel/config
import ../../kernel/traits/scheduler as schedTrait
import ../../kernel/traits/ipc as ipcTrait
import ../../kernel/abi/nimix_abi as abiModule
import ../../kernel/abi/nimix_abi_impl
export schedTrait
export ipcTrait

# ═══════════════════════════════════════════════════════════════════════════
# Constants
# ═══════════════════════════════════════════════════════════════════════════

const
  MkChannelBufSize* = 8    ## Ring-buffer capacity per IPC channel
  ServiceNameLen*   = 64   ## Max service name length
  MaxServices*      = 32   ## Max registered microkernel services

# ═══════════════════════════════════════════════════════════════════════════
# Priority Levels
# ═══════════════════════════════════════════════════════════════════════════

type
  MkPriority* = enum
    mkCritical = 0  ## Kernel services: VFS, driver servers, IPC router
    mkHigh     = 1  ## System tasks: init, service monitors
    mkNormal   = 2  ## Application tasks
    mkLow      = 3  ## Background: logging, statistics, housekeeping

proc toMkPriority*(p: TaskPriority): MkPriority =
  ## Map TaskPriority (0..255) → 4-level microkernel priority.
  if   p >= 192: mkCritical
  elif p >= 128: mkHigh
  elif p >= 64:  mkNormal
  else:          mkLow

# ═══════════════════════════════════════════════════════════════════════════
# Task Table — Priority-aware
# ═══════════════════════════════════════════════════════════════════════════

type
  MkTaskEntry = object
    used:    bool
    state:   TaskState
    entry:   TaskProc
    mkPrio:  MkPriority
    rawPrio: TaskPriority

var
  mkTaskTable:   array[MaxTasks, MkTaskEntry]
  mkTaskCount:   uint32 = 0
  mkCurrentTask: uint32 = 0

# ═══════════════════════════════════════════════════════════════════════════
# Service Registry — named service → ChannelId lookup
# ═══════════════════════════════════════════════════════════════════════════

type
  MkService* = object
    active*:  bool
    name*:    array[ServiceNameLen, char]
    channel*: ChannelId
    owner*:   TaskId

var
  mkServices*:     array[MaxServices, MkService]
  mkServiceTotal*: int = 0

proc fillServiceName(dst: var array[ServiceNameLen, char], src: cstring) =
  for i in 0 ..< ServiceNameLen:
    if src[i] == '\0' or i == ServiceNameLen - 1:
      dst[i] = '\0'
      break
    dst[i] = src[i]

proc serviceNameEq(a: array[ServiceNameLen, char], b: cstring): bool =
  var i = 0
  while i < ServiceNameLen:
    if a[i] != b[i]: return false
    if a[i] == '\0': return true
    inc i
  true

proc mkServiceRegister*(name: cstring, ch: ChannelId, owner: TaskId): bool =
  ## Register a named service. Returns false if registry is full.
  if mkServiceTotal >= MaxServices: return false
  mkServices[mkServiceTotal].active = true
  fillServiceName(mkServices[mkServiceTotal].name, name)
  mkServices[mkServiceTotal].channel = ch
  mkServices[mkServiceTotal].owner   = owner
  inc mkServiceTotal
  true

proc mkServiceLookup*(name: cstring): ChannelId =
  ## Look up a service by name. Returns ChannelId(uint32.high) if not found.
  for i in 0 ..< mkServiceTotal:
    if mkServices[i].active and serviceNameEq(mkServices[i].name, name):
      return mkServices[i].channel
  ChannelId(uint32.high)

# ═══════════════════════════════════════════════════════════════════════════
# Scheduler — Priority Queue
# ═══════════════════════════════════════════════════════════════════════════

proc mkSpawn(entry: TaskProc, priority: TaskPriority): Result[TaskId, SchedulerError] {.nimcall.} =
  if mkTaskCount >= uint32(MaxTasks):
    return Result[TaskId, SchedulerError](isOk: false, error: seOutOfSlots)
  for i in 0 ..< MaxTasks:
    if not mkTaskTable[i].used:
      mkTaskTable[i] = MkTaskEntry(
        used: true, state: tsReady, entry: entry,
        mkPrio: toMkPriority(priority), rawPrio: priority)
      inc mkTaskCount
      return Result[TaskId, SchedulerError](isOk: true, value: TaskId(uint32(i)))
  Result[TaskId, SchedulerError](isOk: false, error: seOutOfSlots)

proc mkYield() {.nimcall.} =
  ## Priority-based yield: scan from highest (Critical) to lowest (Low).
  ## Within each band, round-robin starting after current task.
  for prio in MkPriority:
    var next = (mkCurrentTask + 1) mod uint32(MaxTasks)
    for _ in 0 ..< MaxTasks:
      if mkTaskTable[next].used and
         mkTaskTable[next].state == tsReady and
         mkTaskTable[next].mkPrio == prio:
        mkCurrentTask = next
        return
      next = (next + 1) mod uint32(MaxTasks)

proc mkBlock(id: TaskId): Result[void, SchedulerError] {.nimcall.} =
  let idx = uint32(id)
  if idx >= uint32(MaxTasks) or not mkTaskTable[idx].used:
    return Result[void, SchedulerError](isOk: false, error: seInvalidTask)
  mkTaskTable[idx].state = tsBlocked
  Result[void, SchedulerError](isOk: true)

proc mkWake(id: TaskId): Result[void, SchedulerError] {.nimcall.} =
  let idx = uint32(id)
  if idx >= uint32(MaxTasks) or not mkTaskTable[idx].used:
    return Result[void, SchedulerError](isOk: false, error: seInvalidTask)
  if mkTaskTable[idx].state != tsBlocked:
    return Result[void, SchedulerError](isOk: false, error: seNotBlocked)
  mkTaskTable[idx].state = tsReady
  Result[void, SchedulerError](isOk: true)

proc mkCurrent(): TaskId {.nimcall.} = TaskId(mkCurrentTask)

proc mkExit() {.nimcall.} =
  let idx = mkCurrentTask
  if mkTaskTable[idx].used:
    mkTaskTable[idx].used  = false
    mkTaskTable[idx].state = tsZombie
    if mkTaskCount > 0: dec mkTaskCount
  mkYield()

# ═══════════════════════════════════════════════════════════════════════════
# IPC — Kernel-mediated double-copy via staging buffer
# ═══════════════════════════════════════════════════════════════════════════

type
  MkChannel = object
    isOpen: bool
    head:   uint32
    tail:   uint32
    count:  uint32
    buf:    array[MkChannelBufSize, Message]

var
  mkChannels: array[MaxChannels, MkChannel]
  mkStagingBuf: Message  ## kernel-owned intermediary

proc mkSend(ch: ChannelId, msg: ptr Message): IpcResult {.nimcall.} =
  let idx = uint32(ch)
  if idx >= uint32(MaxChannels) or not mkChannels[idx].isOpen:
    return mrInvalid
  if mkChannels[idx].count >= uint32(MkChannelBufSize):
    return mrFull
  # Step 1: copy into kernel staging buffer (validation point)
  mkStagingBuf = msg[]
  # Step 2: copy from staging into channel slot (relay)
  mkChannels[idx].buf[mkChannels[idx].tail] = mkStagingBuf
  mkChannels[idx].tail = (mkChannels[idx].tail + 1) mod uint32(MkChannelBufSize)
  inc mkChannels[idx].count
  mrOk

proc mkRecv(ch: ChannelId, msg: ptr Message): IpcResult {.nimcall.} =
  let idx = uint32(ch)
  if idx >= uint32(MaxChannels) or not mkChannels[idx].isOpen:
    return mrInvalid
  if mkChannels[idx].count == 0:
    return mrEmpty
  msg[] = mkChannels[idx].buf[mkChannels[idx].head]
  mkChannels[idx].head = (mkChannels[idx].head + 1) mod uint32(MkChannelBufSize)
  dec mkChannels[idx].count
  mrOk

proc mkTryRecv(ch: ChannelId, msg: ptr Message): IpcResult {.nimcall.} =
  mkRecv(ch, msg)

proc mkOpen(): Result[ChannelId, IpcResult] {.nimcall.} =
  for i in 0 ..< MaxChannels:
    if not mkChannels[i].isOpen:
      mkChannels[i] = MkChannel(isOpen: true, head: 0, tail: 0, count: 0)
      return Result[ChannelId, IpcResult](isOk: true, value: ChannelId(uint32(i)))
  Result[ChannelId, IpcResult](isOk: false, error: mrInvalid)

proc mkClose(ch: ChannelId): IpcResult {.nimcall.} =
  let idx = uint32(ch)
  if idx >= uint32(MaxChannels) or not mkChannels[idx].isOpen:
    return mrInvalid
  mkChannels[idx].isOpen = false
  mkChannels[idx].count  = 0
  mrOk

# ═══════════════════════════════════════════════════════════════════════════
# Init — Wire Up Global VTables
# ═══════════════════════════════════════════════════════════════════════════

proc initMicrokernelModel*() =
  ## Populate the global scheduler and IPC vtables with microkernel
  ## implementations. Must be called once during kernel init.

  # Zero task table
  for i in 0 ..< MaxTasks:
    mkTaskTable[i].used  = false
    mkTaskTable[i].state = tsReady
  mkTaskCount   = 0
  mkCurrentTask = 0

  # Zero channel table
  for i in 0 ..< MaxChannels:
    mkChannels[i].isOpen = false
    mkChannels[i].count  = 0

  # Zero service registry
  for i in 0 ..< MaxServices:
    mkServices[i].active = false
  mkServiceTotal = 0

  # Wire scheduler vtable — priority-based
  var sv: SchedulerVTable
  sv.spawn     = mkSpawn
  sv.`yield`   = mkYield
  sv.blockTask = mkBlock
  sv.wake      = mkWake
  sv.current   = mkCurrent
  sv.exit      = mkExit
  schedTrait.scheduler = sv

  # Wire IPC vtable — double-copy staging
  ipcTrait.ipc.send    = mkSend
  ipcTrait.ipc.recv    = mkRecv
  ipcTrait.ipc.tryRecv = mkTryRecv
  ipcTrait.ipc.open    = mkOpen
  ipcTrait.ipc.close   = mkClose

  # Wire app ABI vtable — microkernel: alloc from kernel heap;
  # in a real micro, this would be a separate user-space allocator server.
  proc mkAlloc(size: int): pointer {.nimcall.} = cast[pointer](alloc(size))
  proc mkFree(p: pointer; size: int) {.nimcall.} = dealloc(p)
  var av: abiModule.NimixAbiVTable
  av.allocRegion = mkAlloc
  av.freeRegion  = mkFree
  av.write       = abiWrite
  av.exit        = abiExit
  abiModule.nimixAbi = av
