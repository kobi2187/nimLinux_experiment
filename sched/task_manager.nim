# SPDX-License-Identifier: GPL-2.0
## Task Manager - LAYER 4
##
## Owns task creation and destruction.
## Dependencies: types, heap_manager, virtual_manager, spinlock

import ../core/types
import ../mm/heap_manager
import ../mm/virtual_manager
import ../sync/spinlock
import ../core/serial

type
  # ═══════════════════════════════════════════════════════════════════════════
  # Task State
  # ═══════════════════════════════════════════════════════════════════════════

  TaskState* = enum
    ## Task lifecycle states
    tsCreated     ## Task created but not yet runnable
    tsRunning     ## Currently executing on a CPU
    tsReady       ## Ready to run, in run queue
    tsSleeping    ## Sleeping (timer or wait)
    tsWaiting     ## Waiting on I/O or lock
    tsStopped     ## Stopped by signal
    tsZombie      ## Exited, waiting for parent to collect
    tsDead        ## Can be cleaned up

  # ═══════════════════════════════════════════════════════════════════════════
  # Task Priority
  # ═══════════════════════════════════════════════════════════════════════════

  TaskPriority* = range[0..139]
    ## Task priority (0 = highest, 139 = lowest)
    ## 0-99: Real-time priorities
    ## 100-139: Normal priorities (nice -20 to +19)

const
  DefaultPriority*: TaskPriority = 120    ## Default normal priority
  MaxRtPriority*: TaskPriority = 99       ## Highest RT priority
  MinPriority*: TaskPriority = 139        ## Lowest priority

type
  # ═══════════════════════════════════════════════════════════════════════════
  # CPU Context
  # ═══════════════════════════════════════════════════════════════════════════

  CpuContext* = object
    ## Saved CPU state for context switching (x86_64)
    rsp*: uint64    ## Stack pointer
    rbp*: uint64    ## Base pointer
    rbx*: uint64    ## Callee-saved
    r12*: uint64    ## Callee-saved
    r13*: uint64    ## Callee-saved
    r14*: uint64    ## Callee-saved
    r15*: uint64    ## Callee-saved
    rip*: uint64    ## Instruction pointer (return address)
    rflags*: uint64 ## Flags

  # ═══════════════════════════════════════════════════════════════════════════
  # Task
  # ═══════════════════════════════════════════════════════════════════════════

  Task* = ref object
    ## Task (thread) representation.
    ##
    ## Lifecycle: created → ready → running → (sleeping|waiting) → zombie → dead
    ## Each task has its own address space, kernel stack, and CPU context.

    id*: uint64                   ## Unique PID (persistent across lifecycle)
    name*: array[32, char]        ## Task name (debugging)

    state*: TaskState             ## Current lifecycle state
    priority*: TaskPriority       ## Scheduling priority (0-139)
    flags*: uint32                ## Task flags (RT, system, etc.)

    addressSpace*: AddressSpace   ## Virtual address space (page tables, VMA)
    kernelStack*: VirtAddr        ## Kernel stack base (grows downward)
    kernelStackSize*: uint64      ## Kernel stack size (typically 8KB)
    userStack*: VirtAddr          ## User stack (for user-mode tasks)

    context*: CpuContext          ## Saved context (swapped on schedule)

    cpuTime*: uint64              ## Cumulative CPU time (for fairness)
    lastRun*: uint64              ## Last execution timestamp
    timeSlice*: uint64            ## Remaining ticks in current time slice
    cpu*: int                     ## CPU affinity (-1 = any CPU)

    parent*: Task                 ## Parent task (for hierarchy)
    children*: seq[Task]          ## Child tasks (for cleanup)
    exitCode*: int                ## Exit code (if zombie)

    nextInQueue*: Task            ## Next task in run/wait queue (scheduler)

  # ═══════════════════════════════════════════════════════════════════════════
  # Task Manager
  # ═══════════════════════════════════════════════════════════════════════════

  TaskManager* = ref object
    ## Task manager state
    heap*: HeapManager            ## Heap for allocations
    virtMgr*: VirtualMemManager   ## Virtual memory manager

    # Task tracking
    tasks*: seq[Task]             ## All tasks
    nextId*: uint64               ## Next task ID
    taskCount*: int               ## Active task count

    # Current task (per-CPU in real kernel)
    currentTask*: Task            ## Currently running task

    # Synchronization
    lock*: SpinLock

const
  DefaultKernelStackSize* = 16 * KiB    ## 16KB kernel stack
  DefaultUserStackSize* = 8 * MiB        ## 8MB user stack
  DefaultTimeSlice* = 10'u64             ## Default time slice in ticks

# ═══════════════════════════════════════════════════════════════════════════
# Initialization
# ═══════════════════════════════════════════════════════════════════════════

proc newTaskManager*(heap: HeapManager, virtMgr: VirtualMemManager): TaskManager =
  ## Create a new task manager
  result = TaskManager(
    heap: heap,
    virtMgr: virtMgr,
    tasks: @[],
    nextId: 1,
    taskCount: 0,
    currentTask: nil
  )
  result.lock.init()

# ═══════════════════════════════════════════════════════════════════════════
# Task Creation
# ═══════════════════════════════════════════════════════════════════════════

proc allocKernelStack(self: TaskManager): Result[VirtAddr, KernelError] =
  ## Allocate a kernel stack
  kprintln("    [TASK] allocKernelStack: calling heap.alloc...")
  let stackMem = self.heap.alloc(DefaultKernelStackSize)
  if stackMem.isErr:
    kprintln("    [TASK] ERROR: heap.alloc failed")
    return err(keOutOfMemory)
  kprintln("    [TASK] allocKernelStack: heap.alloc succeeded")
  ok(VirtAddr(cast[uint64](stackMem.value)))

proc setTaskName(task: Task, name: string) =
  ## Set task name
  let copyLen = min(name.len, task.name.len - 1)
  for i in 0..<copyLen:
    task.name[i] = name[i]
  task.name[copyLen] = '\0'

proc createTask*(self: TaskManager, name: string,
                 entryPoint: pointer,
                 parent: Task = nil,
                 priority: TaskPriority = DefaultPriority): Result[Task, KernelError] =
  ## Create a new kernel task
  self.lock.acquire()
  defer: self.lock.release()

  let task = Task(
    id: self.nextId,
    state: tsCreated,
    priority: priority,
    flags: 0,
    cpuTime: 0,
    lastRun: 0,
    timeSlice: DefaultTimeSlice,
    cpu: -1,
    parent: parent,
    children: @[],
    exitCode: 0
  )
  inc self.nextId

  setTaskName(task, name)

  # Create address space (or share with parent for threads)
  if parent != nil and false:  # TODO: implement thread sharing
    task.addressSpace = parent.addressSpace
  else:
    let addrSpace = self.virtMgr.createAddressSpace()
    if addrSpace.isErr:
      return err(keOutOfMemory)
    task.addressSpace = addrSpace.value

  # Allocate kernel stack
  let stack = self.allocKernelStack()
  if stack.isErr:
    self.virtMgr.destroyAddressSpace(task.addressSpace)
    return err(stack.error)
  task.kernelStack = stack.value
  task.kernelStackSize = DefaultKernelStackSize

  # Setup initial context
  let stackTop = task.kernelStack + task.kernelStackSize
  task.context.rsp = uint64(stackTop) - 8  # Leave space for return address
  task.context.rbp = task.context.rsp
  task.context.rip = cast[uint64](entryPoint)
  task.context.rflags = 0x200  # Interrupts enabled

  # Add to task list
  self.tasks.add(task)
  inc self.taskCount

  # Add to parent's children
  if parent != nil:
    parent.children.add(task)

  task.state = tsReady
  ok(task)

proc destroyTask*(self: TaskManager, task: Task): Result[void, KernelError] =
  ## Destroy a task and free its resources
  self.lock.acquire()
  defer: self.lock.release()

  # Free kernel stack
  discard self.heap.free(cast[pointer](task.kernelStack))

  # Destroy address space if not shared
  # TODO: reference counting for shared address spaces
  self.virtMgr.destroyAddressSpace(task.addressSpace)

  # Remove from parent's children
  if task.parent != nil:
    for i, child in task.parent.children:
      if child == task:
        task.parent.children.delete(i)
        break

  # Reparent children to init (task 1) or destroy them
  for child in task.children:
    child.parent = nil  # TODO: reparent to init

  # Remove from task list
  for i, t in self.tasks:
    if t == task:
      self.tasks.delete(i)
      break

  dec self.taskCount
  ok()

# ═══════════════════════════════════════════════════════════════════════════
# Task Operations
# ═══════════════════════════════════════════════════════════════════════════

proc getTask*(self: TaskManager, id: uint64): Option[Task] =
  ## Find task by ID
  self.lock.acquire()
  defer: self.lock.release()

  for task in self.tasks:
    if task.id == id:
      return some(task)
  none(Task)

proc current*(self: TaskManager): Task {.inline.} =
  ## Get currently running task
  self.currentTask

proc setCurrent*(self: TaskManager, task: Task) {.inline.} =
  ## Set currently running task
  self.currentTask = task

proc setState*(task: Task, state: TaskState) {.inline.} =
  ## Set task state
  task.state = state

proc setPriority*(task: Task, priority: TaskPriority) {.inline.} =
  ## Set task priority
  task.priority = priority

# ═══════════════════════════════════════════════════════════════════════════
# Task Enumeration
# ═══════════════════════════════════════════════════════════════════════════

iterator allTasks*(self: TaskManager): Task =
  ## Iterate over all tasks
  self.lock.acquire()
  for task in self.tasks:
    yield task
  self.lock.release()

proc taskCount*(self: TaskManager): int =
  ## Get number of tasks
  self.taskCount

# ═══════════════════════════════════════════════════════════════════════════
# Context Switch Support
# ═══════════════════════════════════════════════════════════════════════════

proc saveContext*(task: Task, ctx: ptr CpuContext) {.inline.} =
  ## Save CPU context to task
  task.context = ctx[]

proc restoreContext*(task: Task, ctx: ptr CpuContext) {.inline.} =
  ## Restore CPU context from task
  ctx[] = task.context
