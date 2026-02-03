# SPDX-License-Identifier: GPL-2.0
## Idle Task - Kernel Thread - LAYER 4
##
## The idle task runs when no other work is available
## One idle task per CPU
## Handles CPU parking and halting
##
## Used by scheduler when ready queue is empty

import ../core/types
import ../core/console
import ../kern/kernel

# ═══════════════════════════════════════════════════════════════════════════
# Idle Task Statistics
# ═══════════════════════════════════════════════════════════════════════════

var
  gIdleTickCount*: uint64 = 0
  gIdleTaskCount*: int = 0

# ═══════════════════════════════════════════════════════════════════════════
# Idle Task Loop
# ═══════════════════════════════════════════════════════════════════════════

proc hlt*() {.inline.} =
  ## Execute HLT (halt) instruction
  ## Pauses CPU until next interrupt
  asm "hlt"

proc nop*() {.inline.} =
  ## Execute NOP (no operation)
  asm "nop"

proc idleTaskLoop*() {.noReturn.} =
  ## Main idle task loop
  ## Runs forever, yielding CPU when no work
  ##
  ## Behavior:
  ## - Check if there's work
  ## - If yes: Scheduler will preempt or yield takes us back
  ## - If no: HLT to save power
  ##
  ## This task NEVER returns (noReturn pragma)

  while true:
    # We're here because scheduler had no work
    # Could spin, sleep, or halt
    # For Phase 1: just halt to save power

    # Count idle ticks
    inc(gIdleTickCount)

    # Multiple NOP instructions for timing
    # (In real kernel, might check work more frequently)
    for i in 0..<100:
      nop()

    # Halt to save CPU cycles
    # Woken by next interrupt/timer tick
    hlt()

# ═══════════════════════════════════════════════════════════════════════════
# Idle Task Creation
# ═══════════════════════════════════════════════════════════════════════════

proc createIdleTask*(cpuId: int, taskManager: pointer): pointer =
  ## Create idle task for specific CPU
  ## Returns Task pointer
  ##
  ## In real implementation, would use proper taskManager
  ## For Phase 1, this is a placeholder showing the interface

  kprintln(fmt"Creating idle task for CPU {cpuId}...")

  # TODO: Actually create task via taskManager
  # For now, just track that we would create it
  inc(gIdleTaskCount)

  nil  # Placeholder return

# ═══════════════════════════════════════════════════════════════════════════
# Idle Task Statistics
# ═══════════════════════════════════════════════════════════════════════════

proc getIdleStats*(): string =
  ## Get idle task statistics
  var result = "Idle Task Statistics:\n"
  result &= fmt"  Idle Ticks: {gIdleTickCount}\n"
  result &= fmt"  Idle Tasks Created: {gIdleTaskCount}\n"
  result

proc resetIdleStats*() =
  ## Reset idle task statistics
  gIdleTickCount = 0
  gIdleTaskCount = 0

# ═══════════════════════════════════════════════════════════════════════════
# Notes on Architecture
# ═══════════════════════════════════════════════════════════════════════════

## IDLE TASK PHILOSOPHY:
##
## The idle task is the lowest priority work in the system.
## It runs when nothing else is available.
##
## WHY HAVE IT?
## 1. CPU goes somewhere when no real work
## 2. Can gather statistics (idle time)
## 3. Can perform background work (if any)
## 4. Can halt/sleep to save power
##
## IDLE LOOP:
## - Infinitely runs (never returns)
## - Checks for work occasionally
## - Halts to save power between checks
## - One per CPU (can be per-core or per-thread)
##
## SCHEDULER INTEGRATION:
## - When ready queue is empty, idle task is selected
## - Idle task allows HLT so CPU can rest
## - Interrupt wakes CPU up again
## - Scheduler selects next runnable task
##
## NEXT STEPS:
## - Integrate with scheduler
## - Add power management (sleep states)
## - Per-CPU idle statistics
## - Idle work queue (for background tasks)
