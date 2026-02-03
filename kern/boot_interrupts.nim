# SPDX-License-Identifier: GPL-2.0
## Interrupt System Boot Setup - LAYER 4
##
## Wires up interrupt system for kernel boot
## Called during kernel_main initialization
##
## Delegates to kern/interrupts.nim for actual IDT management

import ../kern/interrupts
import ../core/console
import ../core/types

# ═══════════════════════════════════════════════════════════════════════════
# Boot Interrupt Initialization
# ═══════════════════════════════════════════════════════════════════════════

proc bootInterruptSystem*(manager: InterruptManager): Result[void, KernelError] =
  ## Initialize interrupt system for kernel boot
  ## Called from kernel_main
  ##
  ## Steps:
  ## 1. Initialize IDT with kernel descriptor
  ## 2. Install default exception handlers
  ## 3. Load IDT into CPU

  kprintln("Initializing interrupt system...")

  # Step 1: Initialize IDT
  # Code segment descriptor: 0x08 (comes from GDT setup in early_init.nim)
  let idtResult = manager.initializeIdt(0x08)

  if idtResult.isErr():
    kprintln("ERROR: IDT initialization failed")
    return err(keInterruptInitFailed)

  kprintln("IDT initialized (256 vectors)")

  # Step 2: Install default exception handlers
  let handlersResult = manager.installDefaultHandlers()

  if handlersResult.isErr():
    kprintln("ERROR: Failed to install exception handlers")
    return err(keInterruptInitFailed)

  kprintln("Default exception handlers installed")

  # Step 3: IDT is loaded (done by kern/interrupts.nim)
  # The IDT register is loaded with LIDT instruction in the module

  kprintln("Interrupt system ready")

  ok()

# ═══════════════════════════════════════════════════════════════════════════
# Handler Registration
# ═══════════════════════════════════════════════════════════════════════════

proc registerBootExceptionHandler*(
    manager: InterruptManager,
    vector: uint32,
    handler: ExceptionHandler): Result[void, KernelError] =
  ## Register exception handler during boot
  ## Delegates to InterruptManager
  ##
  ## Common exception vectors:
  ## 0: Divide by zero
  ## 1: Debug
  ## 3: Breakpoint
  ## 4: Overflow
  ## 5: Bounds
  ## 6: Invalid opcode
  ## 7: Device not available
  ## 8: Double fault
  ## 10: Invalid TSS
  ## 11: Segment not present
  ## 12: Stack fault
  ## 13: General protection fault
  ## 14: Page fault
  ## 16: FPU exception
  ## 17: Alignment check
  ## 18: Machine check
  ## 19: SIMD exception

  manager.registerExceptionHandler(vector, handler)

# ═══════════════════════════════════════════════════════════════════════════
# Interrupt Statistics
# ═══════════════════════════════════════════════════════════════════════════

var gBootInterruptCount*: uint32 = 0

proc recordBootInterrupt*() =
  ## Record that an interrupt occurred
  inc(gBootInterruptCount)

proc getBootInterruptStats*(): string =
  ## Get boot-time interrupt statistics
  var result = "Boot Interrupt Statistics:\n"
  result &= fmt"  Interrupts: {gBootInterruptCount}\n"
  result

# ═══════════════════════════════════════════════════════════════════════════
# Notes on Architecture
# ═══════════════════════════════════════════════════════════════════════════

## BOOT INTERRUPTS PHILOSOPHY:
##
## This module wires up the interrupt system at boot time.
## It's minimal glue code that delegates to kern/interrupts.nim.
##
## WHY SEPARATE MODULE?
## - Separates boot logic from general interrupt management
## - Boot-specific initialization
## - Statistics for boot period
## - Cleaner kernel_main
##
## WHAT WE INITIALIZE:
## 1. IDT (Interrupt Descriptor Table)
##    - 256 entries (0-255)
##    - One per exception/interrupt
##
## 2. Default Handlers
##    - Installed for common exceptions
##    - Can be overridden later
##
## 3. Statistics
##    - Track interrupts during boot
##    - Useful for debugging
##
## WHAT'S NOT DONE YET:
## - IRQ handlers (0-15 from PIC)
## - APIC setup (for SMP)
## - Interrupt masks
## - Per-CPU IDT copies (for SMP)
##
## NEXT STEPS:
## - Timer interrupt setup (TASK in Phase 2)
## - PIC/APIC initialization (Phase 2+)
## - Interrupt masking (Phase 2+)
## - Interrupt handlers for keyboard/IO (Phase 3+)
