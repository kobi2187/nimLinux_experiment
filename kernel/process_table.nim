# SPDX-License-Identifier: GPL-2.0
## Process Table — flat array + intrusive three-class ready rings
##
## Design rationale (see docs/SCHEDULER_DESIGN.md):
##   - Flat array: O(1) access by slot index (hot path: tick update, kill)
##   - Intrusive next/prev per task: class queues with zero heap allocation
##   - Three classes (Realtime > Server > App): pick-next is O(1)
##   - Monotonic PIDs never reused: avoids PID-reuse kill bugs
##   - Separate SchedulerStats struct: `stats` command reads it cheaply

import ../core/log
import ../drivers/pit    # pitTicks()

const
  MaxTasks*    = 32
  TaskNameLen* = 32

type
  TaskClass* = enum
    tcRealtime = 0  ## kernel/IRQ tasks — always scheduled first
    tcServer   = 1  ## OS servers — scheduled second
    tcApp      = 2  ## user ELF apps — scheduled on leftover quanta

  ProcTaskState* = enum
    ptsReady    ## runnable, waiting for its turn
    ptsRunning  ## currently on CPU
    ptsBlocked  ## waiting for event/IPC
    ptsZombie   ## exited, slot pending reclaim

  TaskProc* = proc() {.nimcall.}

  Task* = object
    # ── Slot validity ──────────────────────────────────────────────────────
    used*:       bool

    # ── Identity ───────────────────────────────────────────────────────────
    pid*:        uint32
    name*:       array[TaskNameLen, char]

    # ── Scheduling ─────────────────────────────────────────────────────────
    class*:      TaskClass
    priority*:   uint8          ## 0-255 within class (higher = preferred)
    state*:      ProcTaskState
    entry*:      TaskProc

    # ── Resource tracking ──────────────────────────────────────────────────
    regionSlot*: int32          ## -1 = kernel task (no user region)

    # ── Stats ──────────────────────────────────────────────────────────────
    birthTick*:  uint64         ## pitTicks() at spawn
    cpuTicks*:   uint64         ## quanta consumed
    switches*:   uint64         ## times this task was scheduled

    # ── Intrusive class-ring links ─────────────────────────────────────────
    # next/prev are slot indices into the flat tasks[] array, -1 = none.
    # Each class has its own doubly-linked ring so enqueue/dequeue is O(1).
    classNext*:  int16
    classPrev*:  int16

    # ── Kernel stack (per-task, for context switching) ─────────────────────
    kstack*:     array[4096, byte]   ## 4 KB kernel stack for this task
    rsp*:        uint64              ## saved RSP (set by contextSwitch)

  SchedulerStats* = object
    ticksPerClass*: array[3, uint64]   ## CPU quanta consumed per class
    totalSwitches*: uint64
    idleTicks*:     uint64             ## quanta where no task was ready
    uptimeTicks*:   uint64             ## total scheduler invocations

  ProcessTable* = object
    tasks*:     array[MaxTasks, Task]
    heads*:     array[3, int16]   ## head of each class's ready ring, -1=empty
    current*:   int16             ## currently running slot, -1=idle
    nextPid*:   uint32
    taskCount*: int
    stats*:     SchedulerStats

# ── Global instance ───────────────────────────────────────────────────────────

var procTable*: ProcessTable

# ── Name helpers ──────────────────────────────────────────────────────────────

proc setName*(t: var Task; s: cstring) =
  var i = 0
  while i < TaskNameLen - 1 and s[i] != '\0':
    t.name[i] = s[i]; inc i
  t.name[i] = '\0'

proc getName*(t: Task): cstring =
  cast[cstring](unsafeAddr t.name[0])

# ── Ring operations ───────────────────────────────────────────────────────────

proc ringInsertTail*(pt: var ProcessTable; slot: int16; cls: int) =
  ## Append slot to the tail of class cls's ring.
  let h = pt.heads[cls]
  if h == -1:
    # Empty ring — point to itself
    pt.tasks[slot].classNext = slot
    pt.tasks[slot].classPrev = slot
    pt.heads[cls] = slot
  else:
    # Insert before head (= tail of circular list)
    let tail = pt.tasks[h].classPrev
    pt.tasks[tail].classNext = slot
    pt.tasks[slot].classPrev = tail
    pt.tasks[slot].classNext = h
    pt.tasks[h].classPrev    = slot

proc ringRemove*(pt: var ProcessTable; slot: int16; cls: int) =
  ## Remove slot from class cls's ring.
  let nx = pt.tasks[slot].classNext
  let pv = pt.tasks[slot].classPrev
  if nx == slot:
    # Was the only element
    pt.heads[cls] = -1
  else:
    pt.tasks[pv].classNext = nx
    pt.tasks[nx].classPrev = pv
    if pt.heads[cls] == slot:
      pt.heads[cls] = nx
  pt.tasks[slot].classNext = -1
  pt.tasks[slot].classPrev = -1

# ── Init ──────────────────────────────────────────────────────────────────────

proc procTableInit*() =
  procTable.heads[0] = -1
  procTable.heads[1] = -1
  procTable.heads[2] = -1
  procTable.current  = -1
  procTable.nextPid  = 1      ## PID 0 reserved (idle/invalid)
  procTable.taskCount = 0
  for i in 0 ..< MaxTasks:
    procTable.tasks[i].used      = false
    procTable.tasks[i].classNext = -1
    procTable.tasks[i].classPrev = -1

# ── Spawn ─────────────────────────────────────────────────────────────────────

proc procSpawn*(name: cstring; entry: TaskProc;
                cls: TaskClass; priority: uint8;
                regionSlot: int32 = -1): int =
  ## Allocate a task slot, fill metadata, insert into class ring.
  ## Returns slot index (>=0) or -1 on failure.
  for i in 0 ..< MaxTasks:
    if not procTable.tasks[i].used:
      var t: Task
      t.used       = true
      t.pid        = procTable.nextPid
      t.setName(name)
      t.class      = cls
      t.priority   = priority
      t.state      = ptsReady
      t.entry      = entry
      t.regionSlot = regionSlot
      t.birthTick  = pitTicks()
      t.cpuTicks   = 0
      t.switches   = 0
      t.classNext  = -1
      t.classPrev  = -1
      # Initialize RSP to top of per-task kernel stack (16-byte aligned)
      t.rsp = (cast[uint64](addr t.kstack[4095])) and not 15'u64
      procTable.tasks[i] = t
      # Fix up rsp after copy: point into the copied stack in the table
      procTable.tasks[i].rsp = (cast[uint64](addr procTable.tasks[i].kstack[4095])) and not 15'u64
      inc procTable.nextPid
      inc procTable.taskCount
      ringInsertTail(procTable, int16(i), int(cls))
      klogInt(llInfo, "procSpawn: pid=", int64(t.pid))
      return i
  klog(llError, "procSpawn: MaxTasks reached")
  -1

# ── Kill / reclaim ────────────────────────────────────────────────────────────

proc procKill*(slot: int): bool =
  ## Mark task as zombie and remove from its class ring.
  ## Caller must free regionSlot if >= 0.
  if slot < 0 or slot >= MaxTasks: return false
  if not procTable.tasks[slot].used: return false
  let cls = int(procTable.tasks[slot].class)
  if procTable.tasks[slot].state != ptsBlocked:
    ringRemove(procTable, int16(slot), cls)
  procTable.tasks[slot].state = ptsZombie
  procTable.tasks[slot].used  = false
  dec procTable.taskCount
  true

# ── Pick-next ─────────────────────────────────────────────────────────────────

proc procPickNext*(pt: var ProcessTable): int16 =
  ## O(1): find highest non-empty class, return head of its ring.
  ## Returns -1 if no task is ready (idle).
  for cls in 0 .. 2:
    let h = pt.heads[cls]
    if h == -1: continue
    # Scan within class for a Ready task (skip Blocked/Running/Zombie)
    var slot = h
    for _ in 0 ..< MaxTasks:
      if pt.tasks[slot].state == ptsReady:
        # Rotate ring so next call gets the following task (round-robin)
        pt.heads[cls] = pt.tasks[slot].classNext
        return slot
      slot = pt.tasks[slot].classNext
      if slot == h: break
  -1

# ── Stats update (called on every quantum) ────────────────────────────────────

proc procTickCurrent*(pt: var ProcessTable) =
  let slot = pt.current
  if slot >= 0 and slot < MaxTasks and pt.tasks[slot].used:
    inc pt.tasks[slot].cpuTicks
    inc pt.stats.ticksPerClass[int(pt.tasks[slot].class)]
  else:
    inc pt.stats.idleTicks
  inc pt.stats.uptimeTicks

# ── Find by PID ───────────────────────────────────────────────────────────────

proc procFindPid*(pid: uint32): int =
  ## Linear scan — only called by kill/ps which are human-speed.
  for i in 0 ..< MaxTasks:
    if procTable.tasks[i].used and procTable.tasks[i].pid == pid:
      return i
  -1
