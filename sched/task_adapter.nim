# SPDX-License-Identifier: GPL-2.0
## Task-to-ExecutionModel Adapter - LAYER 4
##
## Bridges traditional Task system with ExecutionModel abstraction
## Allows TaskManager to work with any ExecutionModel (threads, fibers, etc.)
##
## Key Design:
## - Wraps ExecutionUnit with Task metadata
## - Maintains backward compatibility with existing Task code
## - Allows swapping execution models without changing task code

import ../core/types
import ../sync/spinlock
import ./execution_model
import ./task_manager

# ═══════════════════════════════════════════════════════════════════════════
# Task-ExecutionUnit Mapping
# ═══════════════════════════════════════════════════════════════════════════

type
  TaskAdapter* = ref object
    ## Adapts ExecutionUnit to Task interface
    task*: Task                     ## The traditional task
    unit*: ExecutionUnit            ## The execution unit
    model*: ExecutionModel          ## Execution model being used

  TaskAdapterManager* = ref object
    ## Manages task-to-unit mappings
    adapters*: seq[TaskAdapter]
    taskMgr*: TaskManager
    model*: ExecutionModel
    lock*: SpinLock

# ═══════════════════════════════════════════════════════════════════════════
# Conversion Functions
# ═══════════════════════════════════════════════════════════════════════════

proc taskStateToExecState*(state: TaskState): ExecutionState =
  ## Convert TaskState to ExecutionState
  case state
  of tsCreated:
    esReady
  of tsRunning:
    esRunning
  of tsReady:
    esReady
  of tsSleeping, tsWaiting:
    esBlocked
  of tsStopped:
    esSuspended
  of tsZombie, tsDead:
    esTerminated

proc execStateToTaskState*(state: ExecutionState): TaskState =
  ## Convert ExecutionState to TaskState
  case state
  of esReady:
    tsReady
  of esRunning:
    tsRunning
  of esSuspended:
    tsStopped
  of esBlocked:
    tsSleeping  # Could be sleeping or waiting
  of esTerminated:
    tsDead

proc taskPriorityToExecPriority*(prio: TaskPriority): ExecutionPriority =
  ## Convert TaskPriority to ExecutionPriority
  ExecutionPriority(prio)

proc execPriorityToTaskPriority*(prio: ExecutionPriority): TaskPriority =
  ## Convert ExecutionPriority to TaskPriority
  TaskPriority(prio mod 140)

# ═══════════════════════════════════════════════════════════════════════════
# Context Sync
# ═══════════════════════════════════════════════════════════════════════════

proc syncTaskToUnit*(adapter: TaskAdapter) =
  ## Sync task state to execution unit
  adapter.unit.state = taskStateToExecState(adapter.task.state)
  adapter.unit.priority = taskPriorityToExecPriority(adapter.task.priority)

proc syncUnitToTask*(adapter: TaskAdapter) =
  ## Sync execution unit state to task
  adapter.task.state = execStateToTaskState(adapter.unit.state)
  adapter.task.priority = execPriorityToTaskPriority(adapter.unit.priority)

proc syncContextTaskToUnit*(adapter: TaskAdapter) =
  ## Sync task CPU context to execution unit context
  adapter.unit.context.rsp = adapter.task.context.rsp
  adapter.unit.context.rbp = adapter.task.context.rbp
  adapter.unit.context.rbx = adapter.task.context.rbx
  adapter.unit.context.r12 = adapter.task.context.r12
  adapter.unit.context.r13 = adapter.task.context.r13
  adapter.unit.context.r14 = adapter.task.context.r14
  adapter.unit.context.r15 = adapter.task.context.r15
  adapter.unit.context.rip = adapter.task.context.rip
  adapter.unit.context.rflags = adapter.task.context.rflags

proc syncContextUnitToTask*(adapter: TaskAdapter) =
  ## Sync execution unit context to task CPU context
  adapter.task.context.rsp = adapter.unit.context.rsp
  adapter.task.context.rbp = adapter.unit.context.rbp
  adapter.task.context.rbx = adapter.unit.context.rbx
  adapter.task.context.r12 = adapter.unit.context.r12
  adapter.task.context.r13 = adapter.unit.context.r13
  adapter.task.context.r14 = adapter.unit.context.r14
  adapter.task.context.r15 = adapter.unit.context.r15
  adapter.task.context.rip = adapter.unit.context.rip
  adapter.task.context.rflags = adapter.unit.context.rflags

# ═══════════════════════════════════════════════════════════════════════════
# Adapter Manager Operations
# ═══════════════════════════════════════════════════════════════════════════

proc newTaskAdapterManager*(taskMgr: TaskManager, model: ExecutionModel): TaskAdapterManager =
  ## Create new task adapter manager
  result = TaskAdapterManager(
    adapters: @[],
    taskMgr: taskMgr,
    model: model
  )
  result.lock.init()

proc createTaskWithModel*(manager: TaskAdapterManager, name: string,
                         entryPoint: pointer,
                         parent: Task = nil,
                         priority: TaskPriority = DefaultPriority): Result[TaskAdapter, KernelError] =
  ## Create task with execution model support
  manager.lock.acquire()
  defer: manager.lock.release()

  # Create traditional task
  let taskResult = manager.taskMgr.createTask(name, entryPoint, parent, priority)
  if taskResult.isErr:
    return err(taskResult.error)

  let task = taskResult.value

  # Create execution unit in the model
  let unitResult = manager.model.createUnit(taskPriorityToExecPriority(priority))
  if unitResult.isErr:
    discard manager.taskMgr.destroyTask(task)
    return err(keOutOfMemory)

  let unit = unitResult.value
  unit.id = task.id  # Use task ID as unit ID

  # Create adapter
  let adapter = TaskAdapter(
    task: task,
    unit: unit,
    model: manager.model
  )

  # Sync initial state
  adapter.syncTaskToUnit()
  adapter.syncContextTaskToUnit()

  manager.adapters.add(adapter)
  ok(adapter)

proc destroyTaskWithModel*(manager: TaskAdapterManager, adapter: TaskAdapter): Result[void, KernelError] =
  ## Destroy task with execution model cleanup
  manager.lock.acquire()
  defer: manager.lock.release()

  # Destroy execution unit
  let unitResult = manager.model.destroyUnit(adapter.unit)
  if unitResult.isErr:
    return err(keOutOfMemory)

  # Destroy traditional task
  let taskResult = manager.taskMgr.destroyTask(adapter.task)

  # Remove adapter
  for i, a in manager.adapters:
    if a == adapter:
      manager.adapters.del(i)
      break

  if taskResult.isErr:
    return err(taskResult.error)

  ok()

proc getAdapter*(manager: TaskAdapterManager, taskId: uint64): Option[TaskAdapter] =
  ## Get adapter for task ID
  manager.lock.acquire()
  defer: manager.lock.release()

  for adapter in manager.adapters:
    if adapter.task.id == taskId:
      return some(adapter)

  none(TaskAdapter)

proc setTaskState*(manager: TaskAdapterManager, adapter: TaskAdapter, state: TaskState): Result[void, KernelError] =
  ## Set task state (syncs with execution unit)
  let execState = taskStateToExecState(state)
  let result = manager.model.setState(adapter.unit, execState)

  if result.isErr:
    return err(keInvalidOperation)

  adapter.task.state = state
  ok()

proc getTaskState*(manager: TaskAdapterManager, adapter: TaskAdapter): TaskState =
  ## Get task state (from unit)
  let execState = manager.model.getState(adapter.unit)
  execStateToTaskState(execState)

proc enqueueTask*(manager: TaskAdapterManager, adapter: TaskAdapter): Result[void, KernelError] =
  ## Enqueue task to model's ready queue
  let result = manager.model.enqueueUnit(adapter.unit)
  if result.isErr:
    return err(keInvalidOperation)
  ok()

proc dequeueTask*(manager: TaskAdapterManager, adapter: TaskAdapter): Result[void, KernelError] =
  ## Dequeue task from model's ready queue
  let result = manager.model.dequeueUnit(adapter.unit)
  if result.isErr:
    return err(keInvalidOperation)
  ok()

proc switchTasks*(manager: TaskAdapterManager, fromAdapter: TaskAdapter, toAdapter: TaskAdapter): Result[void, KernelError] =
  ## Switch from one task to another via execution model
  # Sync contexts before switch
  fromAdapter.syncContextTaskToUnit()
  toAdapter.syncContextTaskToUnit()

  let result = manager.model.switchTo(fromAdapter.unit, toAdapter.unit)
  if result.isErr:
    return err(keInvalidOperation)

  # Sync states back
  fromAdapter.syncUnitToTask()
  toAdapter.syncUnitToTask()
  fromAdapter.syncContextUnitToTask()
  toAdapter.syncContextUnitToTask()

  ok()

proc suspendTask*(manager: TaskAdapterManager, adapter: TaskAdapter): Result[void, KernelError] =
  ## Suspend task (e.g., waiting for I/O)
  let result = manager.model.suspend(adapter.unit)
  if result.isErr:
    return err(keInvalidOperation)
  adapter.task.state = taskStateToExecState(adapter.unit.state)
  ok()

proc resumeTask*(manager: TaskAdapterManager, adapter: TaskAdapter): Result[void, KernelError] =
  ## Resume suspended task
  let result = manager.model.resume(adapter.unit)
  if result.isErr:
    return err(keInvalidOperation)
  adapter.task.state = execStateToTaskState(adapter.unit.state)
  ok()

# ═══════════════════════════════════════════════════════════════════════════
# Query Operations
# ═══════════════════════════════════════════════════════════════════════════

proc getModelName*(manager: TaskAdapterManager): string =
  ## Get current execution model name
  $manager.model.vtable.name

proc getModelStats*(manager: TaskAdapterManager): string =
  ## Get execution model statistics
  manager.model.getStats()

proc getAdapterCount*(manager: TaskAdapterManager): int =
  ## Get number of task adapters
  manager.adapters.len

proc getAllAdapters*(manager: TaskAdapterManager): seq[TaskAdapter] =
  ## Get all task adapters
  manager.lock.acquire()
  defer: manager.lock.release()
  manager.adapters
