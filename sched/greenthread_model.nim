# SPDX-License-Identifier: GPL-2.0
## Green Thread-based Execution Model - LAYER 3/4
##
## User-space scheduled lightweight threads
## Multiple green threads run on single OS thread
##
## Characteristics:
## - User-space scheduling (no kernel involvement)
## - Non-preemptive (voluntary context switches)
## - Very fast context switching (~50 cycles)
## - Supports 100s of millions of concurrent threads
## - Single-threaded (no SMP)
## - Minimal kernel overhead
## - Cooperative multitasking within process

import ../core/types
import ../sync/spinlock
import ./execution_model

# ═══════════════════════════════════════════════════════════════════════════
# Green Thread Implementation
# ═══════════════════════════════════════════════════════════════════════════

type
  GreenThreadModel* = ref object
    ## Green thread-based execution model implementation
    threads*: seq[ExecutionUnit]
    readyQueue*: seq[ExecutionUnit]
    waitQueue*: seq[ExecutionUnit]
    currentThread*: ExecutionUnit
    lock*: SpinLock

    # Statistics
    created*: uint64
    destroyed*: uint64
    contextSwitches*: uint64
    yields*: uint64
    threadYields*: uint64  ## Explicit thread yields

# ═══════════════════════════════════════════════════════════════════════════
# Green Thread Model Implementation
# ═══════════════════════════════════════════════════════════════════════════

proc newGreenThreadModel*(): GreenThreadModel =
  ## Create new green thread-based execution model
  var model = GreenThreadModel(
    threads: @[],
    readyQueue: @[],
    waitQueue: @[],
    currentThread: nil,
    created: 0,
    destroyed: 0,
    contextSwitches: 0,
    yields: 0,
    threadYields: 0
  )
  model.lock.init()
  model

proc createGreenThreadImpl(model: ExecutionModel, priority: ExecutionPriority): Result[ExecutionUnit, ExecutionUnitError] =
  ## Create new green thread
  let gtModel = cast[GreenThreadModel](model.vtable)

  var unit = ExecutionUnit(
    id: uint64(gtModel.created),
    state: esReady,
    priority: priority,
    context: ExecutionContext()
  )

  inc gtModel.created
  gtModel.threads.add(unit)

  ok(unit)

proc destroyGreenThreadImpl(model: ExecutionModel, unit: ExecutionUnit): Result[void, ExecutionUnitError] =
  ## Destroy green thread
  let gtModel = cast[GreenThreadModel](model.vtable)

  # Remove from queues
  for i in 0..<gtModel.readyQueue.len:
    if gtModel.readyQueue[i].id == unit.id:
      gtModel.readyQueue.del(i)
      break

  for i in 0..<gtModel.waitQueue.len:
    if gtModel.waitQueue[i].id == unit.id:
      gtModel.waitQueue.del(i)
      break

  # Remove from thread list
  for i in 0..<gtModel.threads.len:
    if gtModel.threads[i].id == unit.id:
      gtModel.threads.del(i)
      break

  inc gtModel.destroyed
  ok()

proc setStateImpl(model: ExecutionModel, unit: ExecutionUnit, state: ExecutionState): Result[void, ExecutionUnitError] =
  ## Change green thread state
  if unit.state == esRunning and state == esRunning:
    return err(eeuAlreadyRunning)

  unit.state = state
  ok()

proc getStateImpl(model: ExecutionModel, unit: ExecutionUnit): ExecutionState =
  ## Get green thread state
  unit.state

proc selectNextImpl(model: ExecutionModel): Option[ExecutionUnit] =
  ## Select next green thread to run (priority-based with FIFO within priority)
  let gtModel = cast[GreenThreadModel](model.vtable)

  if gtModel.readyQueue.len == 0:
    return none(ExecutionUnit)

  # Find highest priority (lowest number = highest priority)
  var bestIdx = 0
  var bestPrio = gtModel.readyQueue[0].priority
  for i in 1..<gtModel.readyQueue.len:
    if gtModel.readyQueue[i].priority < bestPrio:
      bestPrio = gtModel.readyQueue[i].priority
      bestIdx = i

  some(gtModel.readyQueue[bestIdx])

proc enqueueGreenThreadImpl(model: ExecutionModel, unit: ExecutionUnit): Result[void, ExecutionUnitError] =
  ## Add green thread to ready queue
  let gtModel = cast[GreenThreadModel](model.vtable)
  gtModel.readyQueue.add(unit)
  ok()

proc dequeueGreenThreadImpl(model: ExecutionModel, unit: ExecutionUnit): Result[void, ExecutionUnitError] =
  ## Remove green thread from ready queue
  let gtModel = cast[GreenThreadModel](model.vtable)
  for i in 0..<gtModel.readyQueue.len:
    if gtModel.readyQueue[i].id == unit.id:
      gtModel.readyQueue.del(i)
      return ok()
  err(eeuNotRunning)

proc saveContextImpl(model: ExecutionModel, unit: ExecutionUnit, ctx: ptr ExecutionContext): Result[void, ExecutionUnitError] =
  ## Save green thread context
  unit.context = ctx[]
  ok()

proc restoreContextImpl(model: ExecutionModel, unit: ExecutionUnit, ctx: ptr ExecutionContext): Result[void, ExecutionUnitError] =
  ## Restore green thread context
  ctx[] = unit.context
  ok()

proc switchToImpl(model: ExecutionModel, from: ExecutionUnit, to: ExecutionUnit): Result[void, ExecutionUnitError] =
  ## Switch from one green thread to another (cooperative)
  let gtModel = cast[GreenThreadModel](model.vtable)
  inc gtModel.contextSwitches

  # Save state of running thread
  if from != nil:
    from.state = esSuspended

  # Restore state of target thread
  to.state = esRunning
  gtModel.currentThread = to

  ok()

proc yieldImpl(model: ExecutionModel): Result[void, ExecutionUnitError] =
  ## Green thread yields CPU to scheduler (cooperative)
  let gtModel = cast[GreenThreadModel](model.vtable)
  inc gtModel.yields
  # In real implementation, would trigger cooperative context switch
  # and move current thread to back of ready queue
  ok()

proc suspendImpl(model: ExecutionModel, unit: ExecutionUnit): Result[void, ExecutionUnitError] =
  ## Suspend green thread (e.g., waiting for I/O)
  if unit.state == esTerminated:
    return err(eeuInvalidState)

  let gtModel = cast[GreenThreadModel](model.vtable)

  # Move from ready to wait queue
  for i in 0..<gtModel.readyQueue.len:
    if gtModel.readyQueue[i].id == unit.id:
      gtModel.readyQueue.del(i)
      break

  unit.state = esBlocked
  gtModel.waitQueue.add(unit)
  ok()

proc resumeImpl(model: ExecutionModel, unit: ExecutionUnit): Result[void, ExecutionUnitError] =
  ## Resume suspended green thread
  if unit.state != esBlocked:
    return err(eeuInvalidState)

  let gtModel = cast[GreenThreadModel](model.vtable)

  # Move from wait to ready queue
  for i in 0..<gtModel.waitQueue.len:
    if gtModel.waitQueue[i].id == unit.id:
      gtModel.waitQueue.del(i)
      break

  unit.state = esReady
  gtModel.readyQueue.add(unit)
  ok()

proc getStatsImpl(model: ExecutionModel): string =
  ## Get green thread model statistics
  let gtModel = cast[GreenThreadModel](model.vtable)

  var result = "Green Thread Model Statistics:\n"
  result &= "  Created: " & $gtModel.created & "\n"
  result &= "  Destroyed: " & $gtModel.destroyed & "\n"
  result &= "  Context Switches: " & $gtModel.contextSwitches & "\n"
  result &= "  Yields: " & $gtModel.yields & "\n"
  result &= "  Total Threads: " & $gtModel.threads.len & "\n"
  result &= "  Ready Queue: " & $gtModel.readyQueue.len & "\n"
  result &= "  Wait Queue: " & $gtModel.waitQueue.len & "\n"
  if gtModel.currentThread != nil:
    result &= "  Current Thread ID: " & $gtModel.currentThread.id & "\n"

  result

# ═══════════════════════════════════════════════════════════════════════════
# Create Green Thread Model Instance
# ═══════════════════════════════════════════════════════════════════════════

proc createGreenThreadModelImpl*(): ExecutionModel =
  ## Create green thread model with vtable
  let gtModel = newGreenThreadModel()

  let vtable = ExecutionModelVTable(
    name: "Green Threads",
    createUnit: createGreenThreadImpl,
    destroyUnit: destroyGreenThreadImpl,
    setState: setStateImpl,
    getState: getStateImpl,
    selectNext: selectNextImpl,
    enqueueUnit: enqueueGreenThreadImpl,
    dequeueUnit: dequeueGreenThreadImpl,
    saveContext: saveContextImpl,
    restoreContext: restoreContextImpl,
    switchTo: switchToImpl,
    yield: yieldImpl,
    suspend: suspendImpl,
    resume: resumeImpl,
    getStats: getStatsImpl
  )

  ExecutionModel(
    vtable: addr vtable
  )
