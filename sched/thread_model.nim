# SPDX-License-Identifier: GPL-2.0
## Thread-based Execution Model
##
## Traditional preemptive kernel threads
## Each thread has independent stack and can be interrupted
##
## Characteristics:
## - Preemptive scheduling (scheduler can interrupt at any time)
## - Each thread has separate stack
## - Full context switch overhead
## - Supports SMP (symmetric multiprocessing)
## - Suitable for CPU-bound and I/O-bound tasks

import ../core/types
import ../sync/spinlock
import ../mm/virtual_manager
import ./execution_model

type
  ThreadModel* = ref object
    ## Thread-based execution model implementation
    threads*: seq[ExecutionUnit]
    readyQueue*: seq[ExecutionUnit]
    lock*: SpinLock

    # Statistics
    created*: uint64
    destroyed*: uint64
    contextSwitches*: uint64

# ═══════════════════════════════════════════════════════════════════════════
# Thread Model Implementation
# ═══════════════════════════════════════════════════════════════════════════

proc newThreadModel*(): ThreadModel =
  ## Create new thread-based execution model
  var model = ThreadModel(
    threads: @[],
    readyQueue: @[],
    created: 0,
    destroyed: 0,
    contextSwitches: 0
  )
  model.lock.init()
  model

proc createThreadImpl(model: ExecutionModel, priority: ExecutionPriority): Result[ExecutionUnit, ExecutionUnitError] =
  ## Create new thread
  let threadModel = cast[ThreadModel](model.vtable)

  var unit = ExecutionUnit(
    id: uint64(threadModel.created),
    state: esReady,
    priority: priority,
    context: ExecutionContext()
  )

  inc threadModel.created

  ok(unit)

proc destroyThreadImpl(model: ExecutionModel, unit: ExecutionUnit): Result[void, ExecutionUnitError] =
  ## Destroy thread
  let threadModel = cast[ThreadModel](model.vtable)
  inc threadModel.destroyed
  ok()

proc setStateImpl(model: ExecutionModel, unit: ExecutionUnit, state: ExecutionState): Result[void, ExecutionUnitError] =
  ## Change thread state
  if unit.state == esRunning and state == esRunning:
    return err(eeuAlreadyRunning)

  unit.state = state
  ok()

proc getStateImpl(model: ExecutionModel, unit: ExecutionUnit): ExecutionState =
  ## Get thread state
  unit.state

proc selectNextImpl(model: ExecutionModel): Option[ExecutionUnit] =
  ## Select next thread to run (round-robin)
  let threadModel = cast[ThreadModel](model.vtable)

  if threadModel.readyQueue.len > 0:
    return some(threadModel.readyQueue[0])

  none(ExecutionUnit)

proc enqueueThreadImpl(model: ExecutionModel, unit: ExecutionUnit): Result[void, ExecutionUnitError] =
  ## Add thread to ready queue
  let threadModel = cast[ThreadModel](model.vtable)
  threadModel.readyQueue.add(unit)
  ok()

proc dequeueThreadImpl(model: ExecutionModel, unit: ExecutionUnit): Result[void, ExecutionUnitError] =
  ## Remove thread from ready queue
  let threadModel = cast[ThreadModel](model.vtable)
  for i in 0..<threadModel.readyQueue.len:
    if threadModel.readyQueue[i].id == unit.id:
      threadModel.readyQueue.del(i)
      return ok()
  err(eeuNotRunning)

proc saveContextImpl(model: ExecutionModel, unit: ExecutionUnit, ctx: ptr ExecutionContext): Result[void, ExecutionUnitError] =
  ## Save thread context
  unit.context = ctx[]
  ok()

proc restoreContextImpl(model: ExecutionModel, unit: ExecutionUnit, ctx: ptr ExecutionContext): Result[void, ExecutionUnitError] =
  ## Restore thread context
  ctx[] = unit.context
  ok()

proc switchToImpl(model: ExecutionModel, fromUnit: ExecutionUnit, to: ExecutionUnit): Result[void, ExecutionUnitError] =
  ## Switch from one thread to another
  let threadModel = cast[ThreadModel](model.vtable)
  inc threadModel.contextSwitches
  fromUnit.state = esSuspended
  to.state = esRunning

  ok()

proc yieldImpl(model: ExecutionModel): Result[void, ExecutionUnitError] =
  ## Thread yields CPU to scheduler
  # In real implementation, would trigger context switch
  ok()

proc suspendImpl(model: ExecutionModel, unit: ExecutionUnit): Result[void, ExecutionUnitError] =
  ## Suspend thread (e.g., waiting for I/O)
  if unit.state == esTerminated:
    return err(eeuInvalidState)

  unit.state = esBlocked
  ok()

proc resumeImpl(model: ExecutionModel, unit: ExecutionUnit): Result[void, ExecutionUnitError] =
  ## Resume suspended thread
  if unit.state != esBlocked:
    return err(eeuInvalidState)

  unit.state = esReady
  ok()

proc getStatsImpl(model: ExecutionModel): string =
  ## Get thread model statistics
  let threadModel = cast[ThreadModel](model.vtable)

  var result = "Thread Model Statistics:\n"
  result &= "  Created: " & $threadModel.created & "\n"
  result &= "  Destroyed: " & $threadModel.destroyed & "\n"
  result &= "  Context Switches: " & $threadModel.contextSwitches & "\n"
  result &= "  Ready Queue: " & $threadModel.readyQueue.len & "\n"

  result

# ═══════════════════════════════════════════════════════════════════════════
# Create Thread Model Instance
# ═══════════════════════════════════════════════════════════════════════════

proc createThreadModelImpl*(): ExecutionModel =
  ## Create thread model with vtable
  let threadModel = newThreadModel()

  let vtable = ExecutionModelVTable(
    name: "Threads",
    createUnit: createThreadImpl,
    destroyUnit: destroyThreadImpl,
    setState: setStateImpl,
    getState: getStateImpl,
    selectNext: selectNextImpl,
    enqueueUnit: enqueueThreadImpl,
    dequeueUnit: dequeueThreadImpl,
    saveContext: saveContextImpl,
    restoreContext: restoreContextImpl,
    switchTo: switchToImpl,
    doYield: yieldImpl,
    suspend: suspendImpl,
    resume: resumeImpl,
    getStats: getStatsImpl
  )

  ExecutionModel(
    vtable: addr vtable
  )
