# SPDX-License-Identifier: GPL-2.0
## Execution Model Abstraction - LAYER 3/4
##
## Defines the interface for different execution models (threads, fibers, coroutines)
## This allows swapping between execution strategies without changing the kernel
##
## Supported Models:
## - Threads: Traditional preemptive kernel threads
## - Fibers: Lightweight non-preemptive coroutines
## - Green Threads: User-space scheduled threads
## - Work-Stealing: Async work-stealing queues
##
## Key Design: Each model implements the same interface, enabling composition

import ../core/types
import ../sync/spinlock
import ../mm/virtual_manager

# ═══════════════════════════════════════════════════════════════════════════
# Execution Context - Model-agnostic CPU state
# ═══════════════════════════════════════════════════════════════════════════

type
  ExecutionContext* = object
    ## CPU state for context switching (model-independent)
    ## Can be expanded with model-specific data
    rsp*: uint64         ## Stack pointer
    rbp*: uint64         ## Base pointer
    rbx*: uint64         ## Callee-saved
    r12*: uint64         ## Callee-saved
    r13*: uint64         ## Callee-saved
    r14*: uint64         ## Callee-saved
    r15*: uint64         ## Callee-saved
    rip*: uint64         ## Instruction pointer
    rflags*: uint64      ## Flags
    # Model-specific can store additional data in heap

  ExecutionState* = enum
    ## Generic execution states (model-independent)
    esReady       ## Ready to execute
    esRunning     ## Currently executing
    esSuspended   ## Suspended (voluntary)
    esBlocked     ## Blocked (waiting for resource)
    esTerminated  ## Terminated, resources freed

  ExecutionPriority* = range[0..255]
    ## Generic priority (0 = highest, 255 = lowest)

# ═══════════════════════════════════════════════════════════════════════════
# Execution Unit - Minimal interface
# ═══════════════════════════════════════════════════════════════════════════

type
  ExecutionUnit* = ref object
    ## Represents a single unit of execution
    ## Can be: thread, fiber, coroutine, task, etc.
    id*: uint64
    state*: ExecutionState
    priority*: ExecutionPriority
    context*: ExecutionContext
    # Model-specific fields stored separately

  ExecutionUnitError* = enum
    eeuSuccess = 0
    eeuInvalidState      ## Invalid state transition
    eeuAlreadyRunning    ## Already running
    eeuNotRunning        ## Not currently running
    eeuOutOfResources    ## Cannot create execution unit
    eeuInvalidModel      ## Invalid execution model

# ═══════════════════════════════════════════════════════════════════════════
# Execution Model Trait
# ═══════════════════════════════════════════════════════════════════════════

type
  ExecutionModel* = ref object
    ## Abstract execution model
    ## Defines how execution units behave
    vtable*: ptr ExecutionModelVTable

  ExecutionModelVTable* = object
    ## Virtual table for execution model operations
    name*: cstring

    # Unit lifecycle
    createUnit*: proc(model: ExecutionModel, priority: ExecutionPriority): Result[ExecutionUnit, ExecutionUnitError] {.nimcall.}
    destroyUnit*: proc(model: ExecutionModel, unit: ExecutionUnit): Result[void, ExecutionUnitError] {.nimcall.}

    # State management
    setState*: proc(model: ExecutionModel, unit: ExecutionUnit, state: ExecutionState): Result[void, ExecutionUnitError] {.nimcall.}
    getState*: proc(model: ExecutionModel, unit: ExecutionUnit): ExecutionState {.nimcall.}

    # Scheduling
    selectNext*: proc(model: ExecutionModel): Option[ExecutionUnit] {.nimcall.}
    enqueueUnit*: proc(model: ExecutionModel, unit: ExecutionUnit): Result[void, ExecutionUnitError] {.nimcall.}
    dequeueUnit*: proc(model: ExecutionModel, unit: ExecutionUnit): Result[void, ExecutionUnitError] {.nimcall.}

    # Context switching
    saveContext*: proc(model: ExecutionModel, unit: ExecutionUnit, ctx: ptr ExecutionContext): Result[void, ExecutionUnitError] {.nimcall.}
    restoreContext*: proc(model: ExecutionModel, unit: ExecutionUnit, ctx: ptr ExecutionContext): Result[void, ExecutionUnitError] {.nimcall.}
    switchTo*: proc(model: ExecutionModel, from: ExecutionUnit, to: ExecutionUnit): Result[void, ExecutionUnitError] {.nimcall.}

    # Model-specific operations
    yield*: proc(model: ExecutionModel): Result[void, ExecutionUnitError] {.nimcall.}
    suspend*: proc(model: ExecutionModel, unit: ExecutionUnit): Result[void, ExecutionUnitError] {.nimcall.}
    resume*: proc(model: ExecutionModel, unit: ExecutionUnit): Result[void, ExecutionUnitError] {.nimcall.}

    # Statistics
    getStats*: proc(model: ExecutionModel): string {.nimcall.}

# ═══════════════════════════════════════════════════════════════════════════
# Execution Model Interface
# ═══════════════════════════════════════════════════════════════════════════

proc createUnit*(model: ExecutionModel, priority: ExecutionPriority): Result[ExecutionUnit, ExecutionUnitError] =
  ## Create new execution unit in this model
  model.vtable.createUnit(model, priority)

proc destroyUnit*(model: ExecutionModel, unit: ExecutionUnit): Result[void, ExecutionUnitError] =
  ## Destroy execution unit
  model.vtable.destroyUnit(model, unit)

proc setState*(model: ExecutionModel, unit: ExecutionUnit, state: ExecutionState): Result[void, ExecutionUnitError] =
  ## Change unit state
  model.vtable.setState(model, unit, state)

proc getState*(model: ExecutionModel, unit: ExecutionUnit): ExecutionState =
  ## Get current unit state
  model.vtable.getState(model, unit)

proc selectNext*(model: ExecutionModel): Option[ExecutionUnit] =
  ## Select next unit to run (scheduler call)
  model.vtable.selectNext(model)

proc enqueueUnit*(model: ExecutionModel, unit: ExecutionUnit): Result[void, ExecutionUnitError] =
  ## Add unit to ready queue
  model.vtable.enqueueUnit(model, unit)

proc dequeueUnit*(model: ExecutionModel, unit: ExecutionUnit): Result[void, ExecutionUnitError] =
  ## Remove unit from ready queue
  model.vtable.dequeueUnit(model, unit)

proc saveContext*(model: ExecutionModel, unit: ExecutionUnit, ctx: ptr ExecutionContext): Result[void, ExecutionUnitError] =
  ## Save execution context
  model.vtable.saveContext(model, unit, ctx)

proc restoreContext*(model: ExecutionModel, unit: ExecutionUnit, ctx: ptr ExecutionContext): Result[void, ExecutionUnitError] =
  ## Restore execution context
  model.vtable.restoreContext(model, unit, ctx)

proc switchTo*(model: ExecutionModel, from: ExecutionUnit, to: ExecutionUnit): Result[void, ExecutionUnitError] =
  ## Switch from one unit to another
  model.vtable.switchTo(model, from, to)

proc yield*(model: ExecutionModel): Result[void, ExecutionUnitError] =
  ## Yield current execution (cooperative)
  model.vtable.yield(model)

proc suspend*(model: ExecutionModel, unit: ExecutionUnit): Result[void, ExecutionUnitError] =
  ## Suspend execution unit
  model.vtable.suspend(model, unit)

proc resume*(model: ExecutionModel, unit: ExecutionUnit): Result[void, ExecutionUnitError] =
  ## Resume execution unit
  model.vtable.resume(model, unit)

proc getStats*(model: ExecutionModel): string =
  ## Get model statistics
  model.vtable.getStats(model)

# ═══════════════════════════════════════════════════════════════════════════
# Scheduler Abstraction - Works with any Execution Model
# ═══════════════════════════════════════════════════════════════════════════

type
  SchedulingAlgorithm* = enum
    saRoundRobin     ## Round-robin scheduling
    saPriority       ## Priority-based scheduling
    saCFS            ## Completely Fair Scheduler
    saWorkStealing   ## Work-stealing scheduler

  GenericScheduler* = ref object
    ## Generic scheduler that works with any execution model
    model*: ExecutionModel
    algorithm*: SchedulingAlgorithm
    currentUnit*: ExecutionUnit
    lock*: SpinLock

    # Statistics
    totalContextSwitches*: uint64
    totalYields*: uint64

# ═══════════════════════════════════════════════════════════════════════════
# Pluggable Components
# ═══════════════════════════════════════════════════════════════════════════

type
  ContextSwitcher* = proc(from: ExecutionContext, to: ExecutionContext): void {.nimcall.}
    ## Low-level context switch implementation

  UnitAllocator* = proc(priority: ExecutionPriority): Result[ExecutionUnit, ExecutionUnitError] {.nimcall.}
    ## Custom allocator for execution units

  SchedulingStrategy* = proc(model: ExecutionModel): Option[ExecutionUnit] {.nimcall.}
    ## Custom scheduling strategy

# ═══════════════════════════════════════════════════════════════════════════
# Model Comparison
# ═══════════════════════════════════════════════════════════════════════════

type
  ModelCharacteristics* = object
    ## Compare different execution models
    name*: string
    preemptive*: bool           ## Can be interrupted by scheduler
    stackRequired*: bool        ## Needs separate stack
    contextSwitchCost*: uint32  ## Relative cost (cycles)
    maxConcurrent*: uint64      ## Max concurrent units
    supportsSMP*: bool          ## Supports multi-CPU

const
  # Characteristics of different models
  ThreadCharacteristics* = ModelCharacteristics(
    name: "Threads",
    preemptive: true,
    stackRequired: true,
    contextSwitchCost: 1000,
    maxConcurrent: 1_000_000,
    supportsSMP: true
  )

  FiberCharacteristics* = ModelCharacteristics(
    name: "Fibers",
    preemptive: false,
    stackRequired: true,
    contextSwitchCost: 100,
    maxConcurrent: 10_000_000,
    supportsSMP: false
  )

  GreenThreadCharacteristics* = ModelCharacteristics(
    name: "Green Threads",
    preemptive: false,
    stackRequired: true,
    contextSwitchCost: 50,
    maxConcurrent: 100_000_000,
    supportsSMP: false
  )

  AsyncCharacteristics* = ModelCharacteristics(
    name: "Async/Await",
    preemptive: false,
    stackRequired: false,
    contextSwitchCost: 10,
    maxConcurrent: 1_000_000_000,
    supportsSMP: false
  )

# ═══════════════════════════════════════════════════════════════════════════
# Model Traits Comparison
# ═══════════════════════════════════════════════════════════════════════════

proc compareModels*(): string =
  ## Compare characteristics of different execution models
  var result = "Execution Model Characteristics:\n"
  result &= "\nThreads:\n"
  result &= "  Preemptive: " & $ThreadCharacteristics.preemptive & "\n"
  result &= "  Stack Required: " & $ThreadCharacteristics.stackRequired & "\n"
  result &= "  Context Switch Cost: " & $ThreadCharacteristics.contextSwitchCost & " cycles\n"
  result &= "  Max Concurrent: " & $ThreadCharacteristics.maxConcurrent & "\n"
  result &= "  SMP Support: " & $ThreadCharacteristics.supportsSMP & "\n"

  result &= "\nFibers:\n"
  result &= "  Preemptive: " & $FiberCharacteristics.preemptive & "\n"
  result &= "  Stack Required: " & $FiberCharacteristics.stackRequired & "\n"
  result &= "  Context Switch Cost: " & $FiberCharacteristics.contextSwitchCost & " cycles\n"
  result &= "  Max Concurrent: " & $FiberCharacteristics.maxConcurrent & "\n"
  result &= "  SMP Support: " & $FiberCharacteristics.supportsSMP & "\n"

  result &= "\nGreen Threads:\n"
  result &= "  Preemptive: " & $GreenThreadCharacteristics.preemptive & "\n"
  result &= "  Stack Required: " & $GreenThreadCharacteristics.stackRequired & "\n"
  result &= "  Context Switch Cost: " & $GreenThreadCharacteristics.contextSwitchCost & " cycles\n"
  result &= "  Max Concurrent: " & $GreenThreadCharacteristics.maxConcurrent & "\n"
  result &= "  SMP Support: " & $GreenThreadCharacteristics.supportsSMP & "\n"

  result &= "\nAsync/Await:\n"
  result &= "  Preemptive: " & $AsyncCharacteristics.preemptive & "\n"
  result &= "  Stack Required: " & $AsyncCharacteristics.stackRequired & "\n"
  result &= "  Context Switch Cost: " & $AsyncCharacteristics.contextSwitchCost & " cycles\n"
  result &= "  Max Concurrent: " & $AsyncCharacteristics.maxConcurrent & "\n"
  result &= "  SMP Support: " & $AsyncCharacteristics.supportsSMP & "\n"

  result
