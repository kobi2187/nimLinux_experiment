# SPDX-License-Identifier: GPL-2.0
## Scheduler Trait — Interface Only
##
## Any scheduler implementation must fill a SchedulerVTable and assign it
## to the global `scheduler` var. Code that needs scheduling imports this
## module only — never a concrete model.

import ../../core/types

type
  TaskId* = distinct uint32
    ## Opaque task identifier. Distinct type prevents accidental confusion
    ## with plain integers.

  TaskPriority* = range[0..255]
    ## Scheduling priority. 0 = lowest, 255 = highest (real-time).

  TaskState* = enum
    tsReady    ## Task is runnable
    tsRunning  ## Task is currently executing on a CPU
    tsBlocked  ## Task is waiting for an event
    tsSleeping ## Task is waiting for a timer
    tsZombie   ## Task has exited, awaiting cleanup

  TaskProc* = proc() {.nimcall.}
    ## Entry point for a new task. Takes no arguments.
    ## Use closures or IPC messages to pass data to tasks.

  SchedulerError* = enum
    seOk         = 0
    seOutOfSlots    ## MaxTasks limit reached
    seInvalidTask   ## TaskId does not exist
    seNotBlocked    ## Cannot wake a task that is not blocked

  SchedulerVTable* = object
    ## Virtual dispatch table for the scheduler.
    ## Set by the chosen kernel model during init.
    spawn*:   proc(entry: TaskProc, priority: TaskPriority): Result[TaskId, SchedulerError] {.nimcall.}
    `yield`*: proc() {.nimcall.}
    blockTask*: proc(id: TaskId): Result[void, SchedulerError] {.nimcall.}
    wake*:    proc(id: TaskId): Result[void, SchedulerError] {.nimcall.}
    current*: proc(): TaskId {.nimcall.}
    exit*:    proc() {.nimcall.}

proc `==`*(a, b: TaskId): bool {.inline.} = uint32(a) == uint32(b)

var scheduler*: SchedulerVTable
  ## Global scheduler vtable. Populated by the active kernel model at init time.
  ## Code that needs to spawn tasks calls scheduler.spawn(...).
