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
import cap/capability
import ../arch/x86_64/tss

when defined(testing):
  var mockTicks*: uint64

when defined(kernelFull):
  var isrRestore {.importc: "isr_restore".}: uint8   ## label in boot_asm.S
  proc isrRestoreAddr(): uint64 = cast[uint64](addr isrRestore)
else:
  proc isrRestoreAddr(): uint64 = 0   ## host tests never switch to the frame

const
  MaxTasks*    = 32
  KStackSize*  = 16384   ## 4 KB overflowed: abiProcList's frame alone is >4 KB
  KStackCanary = 0x57AC_C0DE_DEAD_BEEF'u64   ## at kstack[0]: overwritten ⇒ overflow
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
    wakeAt*:     uint64         ## pitTicks() value at which to wake (0 = not sleeping)

    # ── Capability token ──────────────────────────────────────────────────
    ipcCap*:     CapToken          ## IPC capability token (NullCap = no IPC access)

    # ── Intrusive class-ring links ─────────────────────────────────────────
    # next/prev are slot indices into the flat tasks[] array, -1 = none.
    # Each class has its own doubly-linked ring so enqueue/dequeue is O(1).
    classNext*:  int16
    classPrev*:  int16

    # ── Kernel stack (per-task, for context switching) ─────────────────────
    kstack* {.align(16).}: array[KStackSize, byte]  ## per-task kernel stack (syscalls, IRQs); aligned: canary + rsp0
    rsp*:        uint64              ## saved RSP (set by contextSwitch/preemptiveSwitch)

    # ── FPU/SSE state (512 bytes, must be 16-byte aligned for fxsave64) ────
    fpuState* {.align(16).}: array[512, byte]  ## fxSave/fxRestore: MUST be 16-aligned (#GP)
    fpuValid*:   bool                ## false = FPU state not yet saved (lazy)

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

# ── Idle task ─────────────────────────────────────────────────────────────────
# Runs when no other task is ready. Halts CPU to save power.
# Compiled only in kernel context (hlt is ring-0 only).
when defined(kernelFull):
  import ../arch/x86_64/cpu_primitives
  proc idleTaskProc*() {.nimcall, noreturn.} =
    while true: hlt()

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
    procTable.tasks[i].ipcCap    = NullCap
    procTable.tasks[i].wakeAt    = 0

# ── Spawn ─────────────────────────────────────────────────────────────────────

proc claimSlot(i: int): ptr Task =
  ## Zero slot i in place and arm its stack canary. In place, not `var t: Task`
  ## + copy: a Task carries its kernel stack, so a temporary would be ~17 KB on
  ## the caller's stack (the 16 KB boot stack sits right above the boot page
  ## tables).
  result = addr procTable.tasks[i]
  zeroMem(result, sizeof(Task))
  cast[ptr uint64](addr result.kstack[0])[] = KStackCanary

proc kstackTop*(i: int): uint64 {.inline.} =
  ## 16-byte aligned top of task i's kernel stack (TSS.rsp0 / initial frames).
  cast[uint64](addr procTable.tasks[i].kstack[KStackSize - 1]) and not 15'u64

proc kstackIntact*(i: int): bool {.inline.} =
  ## False once task i's kernel stack has overflowed into its canary.
  cast[ptr uint64](addr procTable.tasks[i].kstack[0])[] == KStackCanary

proc procSpawn*(name: cstring; entry: TaskProc;
                cls: TaskClass; priority: uint8;
                regionSlot: int32 = -1): int =
  ## Allocate a task slot, fill metadata, insert into class ring.
  ## Returns slot index (>=0) or -1 on failure.
  for i in 0 ..< MaxTasks:
    if not procTable.tasks[i].used:
      let t = claimSlot(i)
      t.used       = true
      t.pid        = procTable.nextPid
      t[].setName(name)
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
      t.ipcCap     = NullCap
      t.wakeAt     = 0
      # Build initial stack frame so contextSwitch can switch TO this task.
      # contextSwitch pops r15,r14,r13,r12,rbx,rbp then does ret.
      # We push: entry address (ret target) + 6 zero callee-saved regs.
      # Stack grows down; kstackTop(i) is the 16-byte aligned top.
      # Build initial stack frame so contextSwitch can switch TO this task.
      # contextSwitch does: pop r15,r14,r13,r12,rbx,rbp; ret
      # Frame layout (low addr = rsp, high addr = top):
      #   [rsp+0]  r15  [rsp+8]  r14  [rsp+16] r13  [rsp+24] r12
      #   [rsp+32] rbx  [rsp+40] rbp  [rsp+48] entry (ret target)
      let stackTop = kstackTop(i)
      let rsp = stackTop - 56
      let frame = cast[ptr UncheckedArray[uint64]](rsp)
      frame[0] = 0  # r15
      frame[1] = 0  # r14
      frame[2] = 0  # r13
      frame[3] = 0  # r12
      frame[4] = 0  # rbx
      frame[5] = 0  # rbp
      frame[6] = if entry != nil: cast[uint64](entry) else: 0  # ret → entry
      procTable.tasks[i].rsp = rsp
      inc procTable.nextPid
      inc procTable.taskCount
      # Auto-grant IPC capability to trusted task classes
      if cls in {tcRealtime, tcServer}:
        procTable.tasks[i].ipcCap = capGrant(procTable.tasks[i].pid, capIpc)
      ringInsertTail(procTable, int16(i), int(cls))
      klogInt(llInfo, "procSpawn: pid=", int64(t.pid))
      return i
  klog(llError, "procSpawn: MaxTasks reached")
  -1

proc procAdoptCurrent*(name: cstring; cls: TaskClass): int =
  ## Make the context that is running right now (the boot flow → shell) a real
  ## task, so the scheduler can switch away from it AND back. No initial frame:
  ## its rsp is saved by the first preemptiveSwitch away from it. Before this,
  ## the shell ran as "idle" (current = -1) and its context was discarded on the
  ## first switch to an app, so the shell never answered again.
  assert procTable.current < 0, "procAdoptCurrent: a task is already current"
  for i in 0 ..< MaxTasks:
    if not procTable.tasks[i].used:
      let t = claimSlot(i)
      t.used      = true
      t.pid       = procTable.nextPid
      t[].setName(name)
      t.class     = cls
      t.priority  = 128
      t.state     = ptsRunning
      t.regionSlot = -1
      t.birthTick = pitTicks()
      t.classNext = -1
      t.classPrev = -1
      inc procTable.nextPid
      inc procTable.taskCount
      ringInsertTail(procTable, int16(i), int(cls))
      procTable.current = int16(i)
      return i
  -1

proc procSpawnRing3*(name: cstring; appMain: uint64; userStackTop: uint64;
                     regionSlot: int32): int =
  ## Spawn a ring-3 app task. The kstack is built to look exactly like a task
  ## preempted inside the PIT handler: preemptiveSwitch `ret`s through slot 0
  ## into isr_restore, which pops the GPRs and iretq's into ring 3 at appMain.
  ## (Without slot 0 the `ret` popped the zeroed r15 slot and jumped to address
  ## 0 in ring 0 — the #UD loop at RIP=0x101e, TW#65/TW#72.)
  ##
  ## Frame layout on kstack (low RSP → high):
  ##   [0..7]     return address = isr_restore
  ##   [8..127]   15 GPRs × 8 bytes  (zeroed)
  ##   [128..135] vector_num         (0)
  ##   [136..143] error_code         (0)
  ##   [144..151] RIP  = appMain
  ##   [152..159] CS   = UserCS
  ##   [160..167] RFLAGS = 0x202 (IF=1, reserved bit 1)
  ##   [168..175] RSP  = userStackTop
  ##   [176..183] SS   = UserDS
  ## Total: 184 bytes
  for i in 0 ..< MaxTasks:
    if not procTable.tasks[i].used:
      let t = claimSlot(i)
      t.used       = true
      t.pid        = procTable.nextPid
      t[].setName(name)
      t.class      = tcApp
      t.priority   = 128
      t.state      = ptsReady
      t.entry      = nil
      t.regionSlot = regionSlot
      t.birthTick  = pitTicks()
      t.cpuTicks   = 0
      t.switches   = 0
      t.classNext  = -1
      t.classPrev  = -1
      t.ipcCap     = capGrant(procTable.nextPid, capIpc)
      t.wakeAt     = 0

      let rsp = kstackTop(i) - 184
      let f = cast[ptr UncheckedArray[uint64]](rsp)
      f[0] = isrRestoreAddr()      # preemptiveSwitch `ret` target
      # 15 GPRs (indices 1..15) — all zero
      for j in 1 .. 15: f[j] = 0
      f[16] = 0                    # vector_num
      f[17] = 0                    # error_code
      f[18] = appMain              # RIP
      f[19] = uint64(UserCS)       # CS
      f[20] = 0x202'u64            # RFLAGS: IF=1, bit1 always set
      # SysV ABI: a function is entered with rsp = 8 (mod 16), as if `call`ed (the
      # return address just pushed). appMain is entered by iretq, so make it look
      # called: 16-byte-align the top, then leave room for a return address of 0
      # (a stray return from appMain faults at address 0 and kills the task).
      # Before this the stack was 8 bytes off: harmless for Nim apps, but any C
      # program's aligned SSE stack stores (printf's movaps) raised #GP.
      let entryRsp = (userStackTop and not 15'u64) - 8
      cast[ptr uint64](entryRsp)[] = 0
      f[21] = entryRsp             # RSP (user stack)
      f[22] = uint64(UserDS)       # SS

      procTable.tasks[i].rsp = rsp
      inc procTable.nextPid
      inc procTable.taskCount
      ringInsertTail(procTable, int16(i), int(tcApp))
      klogInt(llInfo, "procSpawnRing3: pid=", int64(t.pid))
      return i
  klog(llError, "procSpawnRing3: MaxTasks reached")
  -1

var onTaskSwitch*: proc(next: int) {.nimcall.}
  ## Called by the preemptive switch with the incoming slot (buffer
  ## enforcement re-applies that task's arena page rights).

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

# ── Sleep / wake ──────────────────────────────────────────────────────────────

proc procSleepUntil*(slot: int; ticks: uint64) =
  ## Block task at slot until pitTicks() >= ticks.
  if slot < 0 or slot >= MaxTasks: return
  if not procTable.tasks[slot].used: return
  procTable.tasks[slot].wakeAt = ticks
  procTable.tasks[slot].state  = ptsBlocked
  ringRemove(procTable, int16(slot), int(procTable.tasks[slot].class))

proc procWakeExpired*(pt: var ProcessTable) =
  ## Check all blocked tasks; wake any whose wakeAt <= now.
  ## Called every PIT tick from pitIrqHandler.
  when defined(testing):
    let now = mockTicks
  else:
    let now = pitTicks()
  for i in 0 ..< MaxTasks:
    if pt.tasks[i].used and pt.tasks[i].state == ptsBlocked and
       pt.tasks[i].wakeAt > 0 and now >= pt.tasks[i].wakeAt:
      pt.tasks[i].wakeAt = 0
      pt.tasks[i].state  = ptsReady
      ringInsertTail(pt, int16(i), int(pt.tasks[i].class))
