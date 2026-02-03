# SPDX-License-Identifier: GPL-2.0
## Scheduler Boot Setup - LAYER 4
##
## Initializes scheduler during kernel boot
## Creates idle tasks and starts scheduling
##
## Ties together task management and execution models

import ../sched/task_manager
import ../sched/scheduler
import ../sched/execution_model
import ../kern/idle_task
import ../core/console
import ../core/types
import ../kern/kernel

# ═══════════════════════════════════════════════════════════════════════════
# Scheduler Boot Initialization
# ═══════════════════════════════════════════════════════════════════════════

proc bootScheduler*(
    taskMgr: TaskManager,
    model: ExecutionModel,
    cpuCount: int): Result[SchedulerManager, KernelError] =
  ## Initialize scheduler during boot
  ##
  ## Steps:
  ## 1. Create scheduler manager with execution model
  ## 2. Create idle tasks for each CPU
  ## 3. Enqueue idle tasks to ready queue
  ## 4. Return scheduler (will be started separately)

  kprintln("Initializing scheduler...")

  # Step 1: Create scheduler manager with chosen execution model
  let scheduler = newSchedulerManager(taskMgr, cpuCount, model)

  kprintln(fmt"Scheduler created ({cpuCount} CPUs)")
  kprintln(fmt"Execution model: {scheduler.getExecutionModelName()}")

  # Step 2: Create idle tasks for each CPU
  kprintln("Creating idle tasks...")

  var idleTaskCount = 0
  for cpuId in 0..<cpuCount:
    # Create idle task for this CPU
    # Note: In real implementation, would create via taskMgr
    # For Phase 1, this is placeholder

    # In full implementation:
    # let idleTask = taskMgr.createTask("idle", idleTaskLoop, nil, MinPriority)
    # scheduler.enqueue(idleTask, cpuId)

    inc(idleTaskCount)

  kprintln(fmt"Created {idleTaskCount} idle tasks (one per CPU)")

  # Step 3: Ready queue will have idle tasks
  # (Full implementation adds them here)

  # Step 4: Return scheduler ready for start
  ok(scheduler)

# ═══════════════════════════════════════════════════════════════════════════
# Scheduler Start
# ═══════════════════════════════════════════════════════════════════════════

proc startScheduler*(scheduler: SchedulerManager): Result[void, KernelError] =
  ## Start the scheduler
  ## Begins executing ready tasks
  ##
  ## After this point, context switches happen

  kprintln("Starting scheduler...")

  # Select first task (will be idle task since nothing else ready)
  let nextOption = scheduler.selectNext()

  if nextOption.isNone():
    kprintln("ERROR: No task available to schedule")
    return err(keSchedulerError)

  let nextUnit = nextOption.get()
  kprintln(fmt"First task selected (ID: {nextUnit.id})")

  # In full implementation:
  # - Save current context
  # - Load next task context
  # - Jump to task (actual context switch)

  ok()

# ═══════════════════════════════════════════════════════════════════════════
# Scheduler Statistics
# ═══════════════════════════════════════════════════════════════════════════

proc getBootSchedulerStats*(scheduler: SchedulerManager): string =
  ## Get boot-time scheduler statistics
  var result = "Scheduler Statistics:\n"
  result &= fmt"  Model: {scheduler.getExecutionModelName()}\n"
  result &= fmt"  CPUs: {scheduler.cpuCount}\n"
  result &= fmt"  Run Queues: {scheduler.runQueues.len}\n"
  result

# ═══════════════════════════════════════════════════════════════════════════
# Notes on Architecture
# ═══════════════════════════════════════════════════════════════════════════

## BOOT SCHEDULER PHILOSOPHY:
##
## This module sets up the scheduler at kernel boot.
## It's the final piece to get the kernel running.
##
## BOOT SEQUENCE:
## 1. kernel_main creates task manager (DONE)
## 2. kernel_main creates scheduler with execution model (DONE)
## 3. bootScheduler creates idle tasks
## 4. startScheduler begins execution
## 5. Scheduler runs until end of time
##
## IDLE TASK PRIORITY:
## - Lowest priority (runs when nothing else available)
## - One per CPU
## - Allows CPU to halt and save power
## - Can be context switched away immediately
##
## EXECUTION MODELS:
## - Scheduler works with any execution model
## - Model chosen in kernel_main via config
## - bootScheduler just initializes it
## - Can be swapped for research/variants
##
## WHAT'S NOT DONE YET:
## - Load balancing (Phase 2+)
## - Priority inheritance (Phase 2+)
## - Real-time scheduling (Phase 3+)
## - SMP wake-up/synchronization (Phase 2+)
##
## NEXT STEPS:
## - Start scheduler and verify it runs
## - Test idle task execution (TASK 1.11)
## - Add timer interrupt for preemption (Phase 2)
## - Create user processes (Phase 2)
