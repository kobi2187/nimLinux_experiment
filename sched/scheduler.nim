# SPDX-License-Identifier: GPL-2.0
## Scheduler Manager - LAYER 4
##
## Owns scheduling decisions and context switching.
## Dependencies: types, task_manager, spinlock

import ../core/types
import ./task_manager
import ../sync/spinlock

type
  # ═══════════════════════════════════════════════════════════════════════════
  # Scheduling Policy
  # ═══════════════════════════════════════════════════════════════════════════

  SchedulerPolicy* = enum
    ## Scheduling policies
    spNormal      ## CFS-like fair scheduling
    spFifo        ## Real-time FIFO
    spRoundRobin  ## Real-time round-robin
    spBatch       ## Batch processing
    spIdle        ## Only when nothing else to run

  # ═══════════════════════════════════════════════════════════════════════════
  # Run Queue
  # ═══════════════════════════════════════════════════════════════════════════

  RunQueue* = ref object
    ## Per-CPU run queue
    cpuId*: int                   ## CPU this queue belongs to
    tasks*: seq[Task]             ## Runnable tasks
    current*: Task                ## Currently running task
    lock*: SpinLock

    # Statistics
    switches*: uint64             ## Context switch count
    totalTasks*: int              ## Total tasks ever queued

  # ═══════════════════════════════════════════════════════════════════════════
  # Scheduler Manager
  # ═══════════════════════════════════════════════════════════════════════════

  SchedulerManager* = ref object
    ## Scheduler manager state
    taskMgr*: TaskManager         ## Task manager dependency

    # Run queues (one per CPU)
    runQueues*: seq[RunQueue]
    cpuCount*: int

    # Idle task
    idleTask*: Task

    # Flags
    needResched*: bool            ## Reschedule needed

    # Synchronization
    lock*: SpinLock

    # Statistics
    totalSwitches*: uint64

const
  DefaultTimeSlice* = 10'u64      ## Default time slice in ticks

# ═══════════════════════════════════════════════════════════════════════════
# Initialization
# ═══════════════════════════════════════════════════════════════════════════

proc newRunQueue(cpuId: int): RunQueue =
  ## Create a new run queue
  result = RunQueue(
    cpuId: cpuId,
    tasks: @[],
    current: nil,
    switches: 0,
    totalTasks: 0
  )
  result.lock.init()

proc newSchedulerManager*(taskMgr: TaskManager, cpuCount: int): SchedulerManager =
  ## Create a new scheduler manager
  result = SchedulerManager(
    taskMgr: taskMgr,
    runQueues: @[],
    cpuCount: cpuCount,
    needResched: false,
    totalSwitches: 0
  )
  result.lock.init()

  # Create per-CPU run queues
  for i in 0..<cpuCount:
    result.runQueues.add(newRunQueue(i))

# ═══════════════════════════════════════════════════════════════════════════
# Run Queue Operations
# ═══════════════════════════════════════════════════════════════════════════

proc enqueue*(self: SchedulerManager, task: Task, cpuId: int = 0) =
  ## Add task to run queue
  let cpu = if cpuId >= 0 and cpuId < self.cpuCount: cpuId else: 0
  let rq = self.runQueues[cpu]

  rq.lock.acquire()
  defer: rq.lock.release()

  task.state = tsReady
  task.timeSlice = DefaultTimeSlice
  rq.tasks.add(task)
  inc rq.totalTasks

proc dequeue*(self: SchedulerManager, cpuId: int = 0): Option[Task] =
  ## Remove highest priority task from run queue
  let rq = self.runQueues[cpuId]

  rq.lock.acquire()
  defer: rq.lock.release()

  if rq.tasks.len == 0:
    return none(Task)

  # Find highest priority (lowest number = highest priority)
  var bestIdx = 0
  var bestPrio = rq.tasks[0].priority
  for i in 1..<rq.tasks.len:
    if rq.tasks[i].priority < bestPrio:
      bestPrio = rq.tasks[i].priority
      bestIdx = i

  let task = rq.tasks[bestIdx]
  rq.tasks.delete(bestIdx)
  some(task)

proc pickNext*(self: SchedulerManager, cpuId: int = 0): Task =
  ## Pick next task to run
  let next = self.dequeue(cpuId)
  if next.isSome:
    return next.get

  # No runnable tasks, return idle task
  if self.idleTask != nil:
    return self.idleTask

  # No idle task either (shouldn't happen)
  nil

proc taskCount*(self: SchedulerManager, cpuId: int = 0): int =
  ## Get number of tasks in run queue
  let rq = self.runQueues[cpuId]
  rq.lock.acquire()
  defer: rq.lock.release()
  rq.tasks.len

# ═══════════════════════════════════════════════════════════════════════════
# Scheduling
# ═══════════════════════════════════════════════════════════════════════════

proc schedule*(self: SchedulerManager, cpuId: int = 0) =
  ## Main scheduling function - pick next task and switch to it
  self.lock.acquire()
  defer: self.lock.release()

  let current = self.taskMgr.current()
  let rq = self.runQueues[cpuId]

  # Re-enqueue current if still runnable
  if current != nil and current.state == tsRunning:
    current.state = tsReady
    self.enqueue(current, cpuId)

  # Pick next task
  let next = self.pickNext(cpuId)

  if next != current and next != nil:
    next.state = tsRunning
    self.taskMgr.setCurrent(next)

    rq.lock.acquire()
    rq.current = next
    inc rq.switches
    rq.lock.release()

    inc self.totalSwitches
    self.needResched = false

    # Context switch would happen here
    # contextSwitch(current, next)

proc scheduleYield*(self: SchedulerManager) =
  ## Voluntary yield - give up CPU
  self.needResched = true
  self.schedule()

proc scheduleSleep*(self: SchedulerManager, task: Task) =
  ## Put task to sleep
  task.state = tsSleeping
  self.needResched = true

proc scheduleWake*(self: SchedulerManager, task: Task, cpuId: int = -1) =
  ## Wake a sleeping task
  if task.state == tsSleeping or task.state == tsWaiting:
    let cpu = if cpuId >= 0: cpuId else: 0  # TODO: select best CPU
    self.enqueue(task, cpu)
    self.needResched = true

# ═══════════════════════════════════════════════════════════════════════════
# Timer/Preemption
# ═══════════════════════════════════════════════════════════════════════════

proc timerTick*(self: SchedulerManager, cpuId: int = 0) =
  ## Called on timer interrupt
  let current = self.taskMgr.current()
  if current == nil:
    return

  # Update CPU time
  inc current.cpuTime

  # Check time slice
  if current.timeSlice > 0:
    dec current.timeSlice
    if current.timeSlice == 0:
      self.needResched = true

proc shouldReschedule*(self: SchedulerManager): bool {.inline.} =
  ## Check if reschedule is needed
  self.needResched

proc setNeedResched*(self: SchedulerManager) {.inline.} =
  ## Set reschedule flag
  self.needResched = true

# ═══════════════════════════════════════════════════════════════════════════
# Priority/Policy Management
# ═══════════════════════════════════════════════════════════════════════════

proc setPolicy*(self: SchedulerManager, task: Task, policy: SchedulerPolicy) =
  ## Set scheduling policy for task
  # Adjust priority based on policy
  case policy
  of spFifo, spRoundRobin:
    if task.priority > MaxRtPriority:
      task.priority = MaxRtPriority
  of spIdle:
    task.priority = MinPriority
  else:
    discard

proc setPriority*(self: SchedulerManager, task: Task, priority: TaskPriority) =
  ## Set task priority
  let oldPrio = task.priority
  task.priority = priority

  # May need to reschedule if priority changed significantly
  if priority < oldPrio:
    self.needResched = true

# ═══════════════════════════════════════════════════════════════════════════
# Load Balancing
# ═══════════════════════════════════════════════════════════════════════════

proc loadBalance*(self: SchedulerManager) =
  ## Balance load across CPUs
  if self.cpuCount <= 1:
    return

  # Find min and max loaded CPUs
  var minCpu = 0
  var maxCpu = 0
  var minLoad = self.runQueues[0].tasks.len
  var maxLoad = minLoad

  for i in 1..<self.cpuCount:
    let load = self.runQueues[i].tasks.len
    if load < minLoad:
      minLoad = load
      minCpu = i
    if load > maxLoad:
      maxLoad = load
      maxCpu = i

  # Migrate if imbalance is significant
  if maxLoad - minLoad > 2:
    let task = self.dequeue(maxCpu)
    if task.isSome:
      self.enqueue(task.get, minCpu)
