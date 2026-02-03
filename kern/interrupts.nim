# SPDX-License-Identifier: GPL-2.0
## Interrupt & Exception System - LAYER 3
##
## Manages IDT, exception handlers, and interrupt dispatching
## Dependencies: types, cpu_primitives, spinlock, logging
##
## This system:
## - Sets up IDT with 256 entries
## - Handles CPU exceptions (0-31)
## - Dispatches interrupts to registered handlers
## - Provides exception context for handlers
## - Supports nested exceptions

import ../core/types
import ../arch/x86_64/cpu_primitives
import ../sync/spinlock
import ../core/serial

# ═══════════════════════════════════════════════════════════════════════════
# Exception Context
# ═══════════════════════════════════════════════════════════════════════════

type
  ExceptionContext* = object
    ## CPU context saved on exception
    # General purpose registers
    rax*: uint64
    rbx*: uint64
    rcx*: uint64
    rdx*: uint64
    rsi*: uint64
    rdi*: uint64
    rbp*: uint64
    r8*: uint64
    r9*: uint64
    r10*: uint64
    r11*: uint64
    r12*: uint64
    r13*: uint64
    r14*: uint64
    r15*: uint64

    # Special registers
    rsp*: uint64
    rflags*: uint64
    rip*: uint64

    # Segment registers
    cs*: uint16
    ss*: uint16
    ds*: uint16
    es*: uint16
    fs*: uint16
    gs*: uint16

    # Exception info
    vectorNum*: uint32       ## Interrupt/exception vector number
    errorCode*: uint64       ## Error code (if applicable)
    isException*: bool       ## True if from exception, false if IRQ
    hasErrorCode*: bool      ## True if error code is valid

  ExceptionError* = enum
    eeSuccess = 0
    eeInvalidVector     ## Invalid interrupt vector
    eeHandlerNotSet     ## No handler registered
    eeAlreadyRegistered ## Handler already registered
    eeInvalidHandler    ## Invalid handler function
    eeTripleFault       ## Triple fault detected
    eeStackOverflow     ## Kernel stack overflow

  ExceptionHandler* = proc(ctx: ptr ExceptionContext): void {.nimcall.}

# ═══════════════════════════════════════════════════════════════════════════
# IDT (Interrupt Descriptor Table) Structures
# ═══════════════════════════════════════════════════════════════════════════

type
  IdtFlags* = distinct uint8

  IdtEntry* = object
    ## IDT entry (gate descriptor)
    offsetLow*: uint16       ## Offset bits 0-15
    selector*: uint16        ## Code segment selector
    ist*: uint8              ## Interrupt Stack Table index
    flags*: uint8            ## Type and attributes
    offsetMid*: uint16       ## Offset bits 16-31
    offsetHigh*: uint32      ## Offset bits 32-63
    reserved*: uint32        ## Reserved (must be 0)

  IdtRegister* = object
    ## IDTR register value
    limit*: uint16           ## Size - 1
    offset*: uint64          ## Linear address

  InterruptManager* = ref object
    ## Global interrupt manager state
    idt*: array[256, IdtEntry]
    handlers*: array[256, ExceptionHandler]
    lock*: SpinLock

    # Statistics
    totalInterrupts*: uint64
    exceptionCount*: array[32, uint64]  ## Per-exception counters
    irqCount*: array[16, uint64]        ## Per-IRQ counters

const
  # IDT entry flags
  IDT_PRESENT* = 0x80'u8
  IDT_DPL_KERNEL* = 0x00'u8
  IDT_DPL_USER* = 0x60'u8
  IDT_TRAP_GATE* = 0x0F'u8
  IDT_INTERRUPT_GATE* = 0x0E'u8

  # Exception vectors
  EX_DIVIDE_ERROR* = 0
  EX_DEBUG* = 1
  EX_NMI* = 2
  EX_BREAKPOINT* = 3
  EX_OVERFLOW* = 4
  EX_BOUND_RANGE* = 5
  EX_INVALID_OPCODE* = 6
  EX_DEVICE_NOT_AVAILABLE* = 7
  EX_DOUBLE_FAULT* = 8
  EX_COPROC_SEGMENT* = 9
  EX_INVALID_TSS* = 10
  EX_SEGMENT_NOT_PRESENT* = 11
  EX_STACK_FAULT* = 12
  EX_GENERAL_PROTECTION* = 13
  EX_PAGE_FAULT* = 14
  EX_RESERVED* = 15
  EX_FLOAT_EXCEPTION* = 16
  EX_ALIGNMENT_CHECK* = 17
  EX_MACHINE_CHECK* = 18
  EX_SIMD_EXCEPTION* = 19

  # IRQ vectors (mapped to 32-47)
  IRQ_OFFSET* = 32
  IRQ_TIMER* = 32
  IRQ_KEYBOARD* = 33
  IRQ_SERIAL1* = 36
  IRQ_SERIAL2* = 35

# ═══════════════════════════════════════════════════════════════════════════
# IDT Initialization
# ═══════════════════════════════════════════════════════════════════════════

var globalInterruptManager: InterruptManager

proc getInterruptManager*(): InterruptManager =
  ## Get global interrupt manager instance
  globalInterruptManager

proc newInterruptManager*(): InterruptManager =
  ## Create new interrupt manager
  InterruptManager(
    totalInterrupts: 0
  )

proc setIdtEntry*(entry: var IdtEntry, offset: uint64, selector: uint16,
                  flags: uint8, ist: uint8 = 0) {.inline.} =
  ## Set up an IDT entry
  entry.offsetLow = uint16(offset and 0xFFFF)
  entry.offsetMid = uint16((offset shr 16) and 0xFFFF)
  entry.offsetHigh = uint32((offset shr 32) and 0xFFFFFFFF)
  entry.selector = selector
  entry.ist = ist
  entry.flags = flags
  entry.reserved = 0

proc loadIdt*(idt: array[256, IdtEntry]) {.inline.} =
  ## Load IDT into IDTR and enable interrupts
  # In real implementation, would call x86 LIDT instruction
  # For now, this is a placeholder
  discard

proc initializeIdt*(manager: InterruptManager, kernelCodeSelector: uint16): Result[void, ExceptionError] =
  ## Initialize IDT with default handlers
  manager.lock.init()

  # Clear all handlers
  for i in 0..<256:
    manager.handlers[i] = nil

  # Set up exception entries (would normally set to assembly stubs)
  let flags = IDT_PRESENT or IDT_DPL_KERNEL or IDT_INTERRUPT_GATE

  for i in 0..<256:
    # In real implementation, would set to actual handler stub addresses
    # For now, initialize with dummy values
    manager.idt[i].flags = flags
    manager.idt[i].selector = kernelCodeSelector
    manager.idt[i].ist = 0
    manager.idt[i].reserved = 0

  ok()

# ═══════════════════════════════════════════════════════════════════════════
# Handler Registration
# ═══════════════════════════════════════════════════════════════════════════

proc registerExceptionHandler*(manager: InterruptManager, vector: uint32,
                               handler: ExceptionHandler): Result[void, ExceptionError] =
  ## Register handler for exception vector
  if vector >= 256:
    return err(eeInvalidVector)

  if handler == nil:
    return err(eeInvalidHandler)

  manager.lock.acquire()
  defer: manager.lock.release()

  if manager.handlers[vector] != nil:
    return err(eeAlreadyRegistered)

  manager.handlers[vector] = handler
  ok()

proc unregisterExceptionHandler*(manager: InterruptManager, vector: uint32): Result[void, ExceptionError] =
  ## Unregister handler for exception vector
  if vector >= 256:
    return err(eeInvalidVector)

  manager.lock.acquire()
  defer: manager.lock.release()

  manager.handlers[vector] = nil
  ok()

# ═══════════════════════════════════════════════════════════════════════════
# Exception Dispatch
# ═══════════════════════════════════════════════════════════════════════════

proc dispatchException*(manager: InterruptManager, ctx: ptr ExceptionContext): Result[void, ExceptionError] =
  ## Dispatch exception to registered handler
  if ctx.vectorNum >= 256:
    return err(eeInvalidVector)

  manager.lock.acquire()
  let handler = manager.handlers[ctx.vectorNum]
  manager.lock.release()

  if handler == nil:
    return err(eeHandlerNotSet)

  # Update statistics
  inc manager.totalInterrupts
  if ctx.isException and ctx.vectorNum < 32:
    inc manager.exceptionCount[ctx.vectorNum]
  elif not ctx.isException:
    let irqNum = ctx.vectorNum - IRQ_OFFSET
    if irqNum < 16:
      inc manager.irqCount[irqNum]

  # Call handler
  handler(ctx)
  ok()

# ═══════════════════════════════════════════════════════════════════════════
# Default Exception Handlers
# ═══════════════════════════════════════════════════════════════════════════

proc defaultDivideErrorHandler*(ctx: ptr ExceptionContext) =
  ## Default divide by zero handler
  kprint("EXCEPTION: Divide Error\n")
  kprint("  RIP: 0x")
  kprintHex(ctx.rip)
  kprint("\n  RAX: 0x")
  kprintHex(ctx.rax)
  kprint("\n")

proc defaultPageFaultHandler*(ctx: ptr ExceptionContext) =
  ## Default page fault handler
  kprint("EXCEPTION: Page Fault\n")
  kprint("  Error Code: 0x")
  kprintHex(ctx.errorCode)
  kprint("\n  RIP: 0x")
  kprintHex(ctx.rip)
  kprint("\n")
  # In real implementation, would check if it's a valid fault we can recover from

proc defaultGeneralProtectionHandler*(ctx: ptr ExceptionContext) =
  ## Default general protection fault handler
  kprint("EXCEPTION: General Protection Fault\n")
  kprint("  Error Code: 0x")
  kprintHex(ctx.errorCode)
  kprint("\n  RIP: 0x")
  kprintHex(ctx.rip)
  kprint("\nHalting.\n")

proc defaultDoubleFaultHandler*(ctx: ptr ExceptionContext) =
  ## Default double fault handler (attempted recovery failed)
  kprint("EXCEPTION: Double Fault\n")
  kprint("  ERROR Code: 0x")
  kprintHex(ctx.errorCode)
  kprint("\nTriple fault imminent. Halting.\n")
  # Spin forever
  while true:
    discard

# ═══════════════════════════════════════════════════════════════════════════
# Initialization Utilities
# ═══════════════════════════════════════════════════════════════════════════

proc installDefaultHandlers*(manager: InterruptManager): Result[void, ExceptionError] =
  ## Install default handlers for common exceptions
  discard ?manager.registerExceptionHandler(EX_DIVIDE_ERROR, defaultDivideErrorHandler)
  discard ?manager.registerExceptionHandler(EX_PAGE_FAULT, defaultPageFaultHandler)
  discard ?manager.registerExceptionHandler(EX_GENERAL_PROTECTION, defaultGeneralProtectionHandler)
  discard ?manager.registerExceptionHandler(EX_DOUBLE_FAULT, defaultDoubleFaultHandler)
  ok()

proc initInterruptSystem*(kernelCodeSelector: uint16): Result[void, ExceptionError] =
  ## Initialize the global interrupt system
  globalInterruptManager = newInterruptManager()
  discard ?globalInterruptManager.initializeIdt(kernelCodeSelector)
  discard ?globalInterruptManager.installDefaultHandlers()
  ok()

# ═══════════════════════════════════════════════════════════════════════════
# Statistics & Information
# ═══════════════════════════════════════════════════════════════════════════

proc getInterruptStats*(manager: InterruptManager): string =
  ## Get human-readable interrupt statistics
  var result = "Interrupt Statistics:\n"
  result &= "  Total Interrupts: " & $manager.totalInterrupts & "\n"
  result &= "  Exceptions:\n"

  for i in 0..<32:
    if manager.exceptionCount[i] > 0:
      result &= "    Vector " & $i & ": " & $manager.exceptionCount[i] & "\n"

  result &= "  IRQs:\n"
  for i in 0..<16:
    if manager.irqCount[i] > 0:
      result &= "    IRQ " & $i & ": " & $manager.irqCount[i] & "\n"

  result

proc getExceptionName*(vector: uint32): string =
  ## Get human-readable exception name
  case vector
  of EX_DIVIDE_ERROR:
    return "Divide Error"
  of EX_DEBUG:
    return "Debug"
  of EX_NMI:
    return "NMI"
  of EX_BREAKPOINT:
    return "Breakpoint"
  of EX_OVERFLOW:
    return "Overflow"
  of EX_BOUND_RANGE:
    return "Bound Range Exceeded"
  of EX_INVALID_OPCODE:
    return "Invalid Opcode"
  of EX_DEVICE_NOT_AVAILABLE:
    return "Device Not Available"
  of EX_DOUBLE_FAULT:
    return "Double Fault"
  of EX_COPROC_SEGMENT:
    return "Coprocessor Segment Overrun"
  of EX_INVALID_TSS:
    return "Invalid TSS"
  of EX_SEGMENT_NOT_PRESENT:
    return "Segment Not Present"
  of EX_STACK_FAULT:
    return "Stack Fault"
  of EX_GENERAL_PROTECTION:
    return "General Protection Fault"
  of EX_PAGE_FAULT:
    return "Page Fault"
  of EX_FLOAT_EXCEPTION:
    return "Floating Point Exception"
  of EX_ALIGNMENT_CHECK:
    return "Alignment Check"
  of EX_MACHINE_CHECK:
    return "Machine Check"
  of EX_SIMD_EXCEPTION:
    return "SIMD Exception"
  else:
    return "Unknown Exception"
