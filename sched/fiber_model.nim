# SPDX-License-Identifier: GPL-2.0
## Fiber-based Execution Model - LAYER 3/4
##
## Lightweight non-preemptive coroutines with separate stacks
## Each fiber yields cooperatively to the scheduler
##
## Characteristics:
## - Lightweight (stackful coroutines)
## - Non-preemptive (voluntary context switches)
## - Very fast context switching (~100 cycles)
## - Supports millions of concurrent fibers
## - Single-threaded (no SMP)
## - Requires explicit yield() calls

import ../core/types
import ../sync/spinlock
import ./execution_model

# ═══════════════════════════════════════════════════════════════════════════
# Fiber Implementation
# ═══════════════════════════════════════════════════════════════════════════

type
  FiberModel* = ref object
    ## Fiber-based execution model implementation
    fibers*: seq[ExecutionUnit]
    readyQueue*: seq[ExecutionUnit]
    waitQueue*: seq[ExecutionUnit]
    lock*: SpinLock

    # Statistics
    created*: uint64
    destroyed*: uint64
    contextSwitches*: uint64
    yields*: uint64

# ═══════════════════════════════════════════════════════════════════════════
# Fiber Model Implementation
# ═══════════════════════════════════════════════════════════════════════════

proc newFiberModel*(): FiberModel =
  ## Create new fiber-based execution model
  var model = FiberModel(
    fibers: @[],
    readyQueue: @[],
    waitQueue: @[],
    created: 0,
    destroyed: 0,
    contextSwitches: 0,
    yields: 0
  )
  model.lock.init()
  model

proc createFiberImpl(model: ExecutionModel, priority: ExecutionPriority): Result[ExecutionUnit, ExecutionUnitError] =
  ## Create new fiber
  let fiberModel = cast[FiberModel](model.vtable)

  var unit = ExecutionUnit(
    id: uint64(fiberModel.created),
    state: esReady,
    priority: priority,
    context: ExecutionContext()
  )

  inc fiberModel.created

  ok(unit)

proc destroyFiberImpl(model: ExecutionModel, unit: ExecutionUnit): Result[void, ExecutionUnitError] =
  ## Destroy fiber
  let fiberModel = cast[FiberModel](model.vtable)
  inc fiberModel.destroyed
  ok()

proc setStateImpl(model: ExecutionModel, unit: ExecutionUnit, state: ExecutionState): Result[void, ExecutionUnitError] =
  ## Change fiber state
  if unit.state == esRunning and state == esRunning:
    return err(eeuAlreadyRunning)

  unit.state = state
  ok()

proc getStateImpl(model: ExecutionModel, unit: ExecutionUnit): ExecutionState =
  ## Get fiber state
  unit.state

proc selectNextImpl(model: ExecutionModel): Option[ExecutionUnit] =
  ## Select next fiber to run (FIFO/round-robin, no preemption)
  let fiberModel = cast[FiberModel](model.vtable)

  if fiberModel.readyQueue.len > 0:
    return some(fiberModel.readyQueue[0])

  none(ExecutionUnit)

proc enqueueFiberImpl(model: ExecutionModel, unit: ExecutionUnit): Result[void, ExecutionUnitError] =
  ## Add fiber to ready queue
  let fiberModel = cast[FiberModel](model.vtable)
  fiberModel.readyQueue.add(unit)
  ok()

proc dequeueFiberImpl(model: ExecutionModel, unit: ExecutionUnit): Result[void, ExecutionUnitError] =
  ## Remove fiber from ready queue
  let fiberModel = cast[FiberModel](model.vtable)
  for i in 0..<fiberModel.readyQueue.len:
    if fiberModel.readyQueue[i].id == unit.id:
      fiberModel.readyQueue.del(i)
      return ok()
  err(eeuNotRunning)

proc saveContextImpl(model: ExecutionModel, unit: ExecutionUnit, ctx: ptr ExecutionContext): Result[void, ExecutionUnitError] =
  ## Save fiber context
  unit.context = ctx[]
  ok()

proc restoreContextImpl(model: ExecutionModel, unit: ExecutionUnit, ctx: ptr ExecutionContext): Result[void, ExecutionUnitError] =
  ## Restore fiber context
  ctx[] = unit.context
  ok()

proc switchToImpl(model: ExecutionModel, fromUnit: ExecutionUnit, to: ExecutionUnit): Result[void, ExecutionUnitError] =
  ## Switch from one fiber to another (cooperative)
  let fiberModel = cast[FiberModel](model.vtable)
  inc fiberModel.contextSwitches
  fromUnit.state = esSuspended
  # Restore state of target fiber
  to.state = esRunning

  ok()

proc yieldImpl(model: ExecutionModel): Result[void, ExecutionUnitError] =
  ## Fiber yields CPU to scheduler (cooperative)
  let fiberModel = cast[FiberModel](model.vtable)
  inc fiberModel.yields
  # In real implementation, would trigger cooperative context switch
  ok()

proc suspendImpl(model: ExecutionModel, unit: ExecutionUnit): Result[void, ExecutionUnitError] =
  ## Suspend fiber (e.g., waiting for I/O)
  if unit.state == esTerminated:
    return err(eeuInvalidState)

  unit.state = esBlocked
  ok()

proc resumeImpl(model: ExecutionModel, unit: ExecutionUnit): Result[void, ExecutionUnitError] =
  ## Resume suspended fiber
  if unit.state != esBlocked:
    return err(eeuInvalidState)

  unit.state = esReady
  ok()

proc getStatsImpl(model: ExecutionModel): string =
  ## Get fiber model statistics
  let fiberModel = cast[FiberModel](model.vtable)

  var result = "Fiber Model Statistics:\n"
  result &= "  Created: " & $fiberModel.created & "\n"
  result &= "  Destroyed: " & $fiberModel.destroyed & "\n"
  result &= "  Context Switches: " & $fiberModel.contextSwitches & "\n"
  result &= "  Yields: " & $fiberModel.yields & "\n"
  result &= "  Ready Queue: " & $fiberModel.readyQueue.len & "\n"
  result &= "  Wait Queue: " & $fiberModel.waitQueue.len & "\n"

  result

# ═══════════════════════════════════════════════════════════════════════════
# Create Fiber Model Instance
# ═══════════════════════════════════════════════════════════════════════════

proc createFiberModelImpl*(): ExecutionModel =
  ## Create fiber model with vtable
  let fiberModel = newFiberModel()

  let vtable = ExecutionModelVTable(
    name: "Fibers",
    createUnit: createFiberImpl,
    destroyUnit: destroyFiberImpl,
    setState: setStateImpl,
    getState: getStateImpl,
    selectNext: selectNextImpl,
    enqueueUnit: enqueueFiberImpl,
    dequeueUnit: dequeueFiberImpl,
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
