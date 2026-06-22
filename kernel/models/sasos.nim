# SPDX-License-Identifier: GPL-2.0
## Single Address Space OS Model (SASOS)
##
## Inspired by Microsoft Research's Singularity OS.
##
## Key idea: all "processes" share one virtual address space.
## Isolation is enforced by Nim's type system, not hardware MMU rings:
##   - Module boundaries are opaque handles (distinct types)
##   - No unsafe pointer sharing between modules
##   - IPC is direct ring-buffer — no kernel mediation, no context switch
##   - Result: microkernel-level safety + monolithic-level speed
##
## Scheduler: Round-robin (same policy as monolithic — SASOS innovation
##   is about isolation, not scheduling).
##
## IPC: Capability-gated direct copy. Same ring-buffer as monolithic
##   (single memcpy, zero kernel mediation) but every send/recv is
##   guarded by unforgeable capability tokens. A SIP that does not hold
##   a capability for a channel gets mrInvalid.
##
## SIP Registry: Software Isolated Processes. Each SIP has an ID, a name,
##   and a set of capability grants. SIPs are the isolation unit — like
##   processes but without separate page tables.
##
## To select: -d:kernelModel=sasos

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
  SasosChannelBufSize* = 8   ## Ring-buffer capacity per IPC channel
  MaxSips*          = 64     ## Max Software Isolated Processes
  MaxCapsPerSip*    = 32     ## Max capabilities per SIP
  SipNameLen*       = 64     ## Max SIP name length

# ═══════════════════════════════════════════════════════════════════════════
# SIP (Software Isolated Process) Registry
# ═══════════════════════════════════════════════════════════════════════════

type
  SipId* = distinct uint32
    ## Opaque Software Isolated Process identifier.

  CapabilityKind* = enum
    capNone         = 0
    capChannelRead  = 1  ## Permission to recv from a channel
    capChannelWrite = 2  ## Permission to send to a channel

  Capability* = object
    valid*:    bool
    kind*:     CapabilityKind
    resource*: uint32        ## Channel ID (or other resource ID)

  SipEntry* = object
    active*: bool
    name*:   array[SipNameLen, char]
    caps:    array[MaxCapsPerSip, Capability]
    capCount: int

proc `==`*(a, b: SipId): bool {.inline.} = uint32(a) == uint32(b)

var
  sipTable:    array[MaxSips, SipEntry]
  sipCount*:   int = 0
  currentSip*: SipId = SipId(0)

proc fillSipName(dst: var array[SipNameLen, char], src: cstring) =
  for i in 0 ..< SipNameLen:
    if src[i] == '\0' or i == SipNameLen - 1:
      dst[i] = '\0'
      break
    dst[i] = src[i]

proc sasosCreateSip*(name: cstring): SipId =
  ## Create a new Software Isolated Process. Returns SipId(uint32.high) on failure.
  if sipCount >= MaxSips:
    return SipId(uint32.high)
  let idx = sipCount
  inc sipCount
  sipTable[idx].active   = true
  sipTable[idx].capCount = 0
  fillSipName(sipTable[idx].name, name)
  for i in 0 ..< MaxCapsPerSip:
    sipTable[idx].caps[i].valid = false
  SipId(uint32(idx))

proc sasosGrantCapability*(sip: SipId, kind: CapabilityKind, resource: uint32): bool =
  ## Grant a capability to a SIP. Returns false if cap table is full.
  let idx = int(uint32(sip))
  if idx < 0 or idx >= sipCount or not sipTable[idx].active:
    return false
  if sipTable[idx].capCount >= MaxCapsPerSip:
    return false
  # Find empty slot
  for i in 0 ..< MaxCapsPerSip:
    if not sipTable[idx].caps[i].valid:
      sipTable[idx].caps[i] = Capability(valid: true, kind: kind, resource: resource)
      inc sipTable[idx].capCount
      return true
  false

proc sasosRevokeCapability*(sip: SipId, kind: CapabilityKind, resource: uint32): bool =
  ## Revoke a specific capability from a SIP.
  let idx = int(uint32(sip))
  if idx < 0 or idx >= sipCount or not sipTable[idx].active:
    return false
  for i in 0 ..< MaxCapsPerSip:
    if sipTable[idx].caps[i].valid and
       sipTable[idx].caps[i].kind == kind and
       sipTable[idx].caps[i].resource == resource:
      sipTable[idx].caps[i].valid = false
      dec sipTable[idx].capCount
      return true
  false

proc sasosHasCapability*(sip: SipId, kind: CapabilityKind, resource: uint32): bool =
  ## Check whether a SIP holds a specific capability.
  let idx = int(uint32(sip))
  if idx < 0 or idx >= sipCount or not sipTable[idx].active:
    return false
  for i in 0 ..< MaxCapsPerSip:
    if sipTable[idx].caps[i].valid and
       sipTable[idx].caps[i].kind == kind and
       sipTable[idx].caps[i].resource == resource:
      return true
  false

proc sasosSetCurrentSip*(sip: SipId) =
  ## Set the currently executing SIP (called by scheduler on context switch).
  currentSip = sip

# ═══════════════════════════════════════════════════════════════════════════
# Task Table — Round-Robin (same policy as monolithic)
# ═══════════════════════════════════════════════════════════════════════════

type
  SasosTaskEntry = object
    used:     bool
    state:    TaskState
    entry:    TaskProc
    priority: TaskPriority
    sipOwner: SipId  ## Which SIP owns this task

var
  sasosTaskTable:   array[MaxTasks, SasosTaskEntry]
  sasosTaskCount:   uint32 = 0
  sasosCurrentTask: uint32 = 0

proc sasosSpawn(entry: TaskProc, priority: TaskPriority): Result[TaskId, SchedulerError] {.nimcall.} =
  if sasosTaskCount >= uint32(MaxTasks):
    return Result[TaskId, SchedulerError](isOk: false, error: seOutOfSlots)
  for i in 0 ..< MaxTasks:
    if not sasosTaskTable[i].used:
      sasosTaskTable[i] = SasosTaskEntry(
        used: true, state: tsReady, entry: entry,
        priority: priority, sipOwner: currentSip)
      inc sasosTaskCount
      return Result[TaskId, SchedulerError](isOk: true, value: TaskId(uint32(i)))
  Result[TaskId, SchedulerError](isOk: false, error: seOutOfSlots)

proc sasosYield() {.nimcall.} =
  var next = (sasosCurrentTask + 1) mod uint32(MaxTasks)
  for _ in 0 ..< MaxTasks:
    if sasosTaskTable[next].used and sasosTaskTable[next].state == tsReady:
      sasosCurrentTask = next
      # Update current SIP to match the task we're switching to
      currentSip = sasosTaskTable[next].sipOwner
      return
    next = (next + 1) mod uint32(MaxTasks)

proc sasosBlock(id: TaskId): Result[void, SchedulerError] {.nimcall.} =
  let idx = uint32(id)
  if idx >= uint32(MaxTasks) or not sasosTaskTable[idx].used:
    return Result[void, SchedulerError](isOk: false, error: seInvalidTask)
  sasosTaskTable[idx].state = tsBlocked
  Result[void, SchedulerError](isOk: true)

proc sasosWake(id: TaskId): Result[void, SchedulerError] {.nimcall.} =
  let idx = uint32(id)
  if idx >= uint32(MaxTasks) or not sasosTaskTable[idx].used:
    return Result[void, SchedulerError](isOk: false, error: seInvalidTask)
  if sasosTaskTable[idx].state != tsBlocked:
    return Result[void, SchedulerError](isOk: false, error: seNotBlocked)
  sasosTaskTable[idx].state = tsReady
  Result[void, SchedulerError](isOk: true)

proc sasosCurrent(): TaskId {.nimcall.} = TaskId(sasosCurrentTask)

proc sasosExit() {.nimcall.} =
  let idx = sasosCurrentTask
  if sasosTaskTable[idx].used:
    sasosTaskTable[idx].used  = false
    sasosTaskTable[idx].state = tsZombie
    if sasosTaskCount > 0: dec sasosTaskCount
  sasosYield()

# ═══════════════════════════════════════════════════════════════════════════
# IPC — Capability-Gated Direct Copy
# ═══════════════════════════════════════════════════════════════════════════
#
# Same ring-buffer as monolithic (single memcpy, no staging buffer) but
# every operation is guarded by capability checks on the current SIP.
# The kernel SIP (SipId 0) is granted all capabilities at init.

type
  SasosChannel = object
    isOpen: bool
    head:   uint32
    tail:   uint32
    count:  uint32
    buf:    array[SasosChannelBufSize, Message]

var
  sasosChannels: array[MaxChannels, SasosChannel]

proc sasosSend(ch: ChannelId, msg: ptr Message): IpcResult {.nimcall.} =
  let idx = uint32(ch)
  if idx >= uint32(MaxChannels) or not sasosChannels[idx].isOpen:
    return mrInvalid
  # ── Capability gate: current SIP must hold write permission ──
  if not sasosHasCapability(currentSip, capChannelWrite, idx):
    return mrInvalid
  if sasosChannels[idx].count >= uint32(SasosChannelBufSize):
    return mrFull
  # Direct copy — no staging buffer (single address space)
  sasosChannels[idx].buf[sasosChannels[idx].tail] = msg[]
  sasosChannels[idx].tail = (sasosChannels[idx].tail + 1) mod uint32(SasosChannelBufSize)
  inc sasosChannels[idx].count
  mrOk

proc sasosRecv(ch: ChannelId, msg: ptr Message): IpcResult {.nimcall.} =
  let idx = uint32(ch)
  if idx >= uint32(MaxChannels) or not sasosChannels[idx].isOpen:
    return mrInvalid
  # ── Capability gate: current SIP must hold read permission ──
  if not sasosHasCapability(currentSip, capChannelRead, idx):
    return mrInvalid
  if sasosChannels[idx].count == 0:
    return mrEmpty
  msg[] = sasosChannels[idx].buf[sasosChannels[idx].head]
  sasosChannels[idx].head = (sasosChannels[idx].head + 1) mod uint32(SasosChannelBufSize)
  dec sasosChannels[idx].count
  mrOk

proc sasosTryRecv(ch: ChannelId, msg: ptr Message): IpcResult {.nimcall.} =
  sasosRecv(ch, msg)

proc sasosOpen(): Result[ChannelId, IpcResult] {.nimcall.} =
  for i in 0 ..< MaxChannels:
    if not sasosChannels[i].isOpen:
      sasosChannels[i] = SasosChannel(isOpen: true, head: 0, tail: 0, count: 0)
      let chId = ChannelId(uint32(i))
      # Auto-grant read+write to the creating SIP
      discard sasosGrantCapability(currentSip, capChannelRead,  uint32(i))
      discard sasosGrantCapability(currentSip, capChannelWrite, uint32(i))
      return Result[ChannelId, IpcResult](isOk: true, value: chId)
  Result[ChannelId, IpcResult](isOk: false, error: mrInvalid)

proc sasosClose(ch: ChannelId): IpcResult {.nimcall.} =
  let idx = uint32(ch)
  if idx >= uint32(MaxChannels) or not sasosChannels[idx].isOpen:
    return mrInvalid
  sasosChannels[idx].isOpen = false
  sasosChannels[idx].count  = 0
  # Revoke all capabilities for this channel across all SIPs
  for s in 0 ..< sipCount:
    discard sasosRevokeCapability(SipId(uint32(s)), capChannelRead,  idx)
    discard sasosRevokeCapability(SipId(uint32(s)), capChannelWrite, idx)
  mrOk

# ═══════════════════════════════════════════════════════════════════════════
# Init — Wire Up Global VTables
# ═══════════════════════════════════════════════════════════════════════════

proc initSasosModel*() =
  ## Initialise the SASOS kernel model.
  ## Creates the kernel SIP (SipId 0) and wires up capability-gated IPC.

  # Zero task table
  for i in 0 ..< MaxTasks:
    sasosTaskTable[i].used  = false
    sasosTaskTable[i].state = tsReady
  sasosTaskCount   = 0
  sasosCurrentTask = 0

  # Zero channel table
  for i in 0 ..< MaxChannels:
    sasosChannels[i].isOpen = false
    sasosChannels[i].count  = 0

  # Zero SIP registry
  for i in 0 ..< MaxSips:
    sipTable[i].active   = false
    sipTable[i].capCount = 0
  sipCount = 0

  # Create kernel SIP (SipId 0) — has all capabilities
  currentSip = sasosCreateSip("kernel")

  # Wire scheduler vtable — round-robin (SASOS tracks SIP ownership)
  var sv: SchedulerVTable
  sv.spawn     = sasosSpawn
  sv.`yield`   = sasosYield
  sv.blockTask = sasosBlock
  sv.wake      = sasosWake
  sv.current   = sasosCurrent
  sv.exit      = sasosExit
  schedTrait.scheduler = sv

  # Wire IPC vtable — capability-gated direct copy
  ipcTrait.ipc.send    = sasosSend
  ipcTrait.ipc.recv    = sasosRecv
  ipcTrait.ipc.tryRecv = sasosTryRecv
  ipcTrait.ipc.open    = sasosOpen
  ipcTrait.ipc.close   = sasosClose

  # Wire app ABI vtable — SASOS: alloc from shared address space region map.
  # Each SIP gets a 1MB-aligned region; for now we use the kernel heap and
  # will replace with the virtual region allocator in the next slice.
  proc sasosAlloc(size: int): pointer {.nimcall.} = cast[pointer](alloc(size))
  proc sasosFree(p: pointer; size: int) {.nimcall.} = dealloc(p)
  var av: abiModule.NimixAbiVTable
  av.allocRegion = sasosAlloc
  av.freeRegion  = sasosFree
  av.write       = abiWrite
  av.exit        = abiExit
  abiModule.nimixAbi = av
