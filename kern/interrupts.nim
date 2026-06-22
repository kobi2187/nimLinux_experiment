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
  ExceptionContext* {.packed.} = object
    ## CPU context saved on exception.
    ## Field order MUST match the assembly push sequence in isr_common_stub exactly.
    ##
    ## Stack layout at nimInterruptDispatch entry (RSP → rax, low addr first):
    ##   [pushed by isr_common_stub]  rax rbx rcx rdx rsi rdi rbp r8..r15
    ##   [pushed by entry stub]       vectorNum  errorCode
    ##   [pushed by CPU on interrupt] rip cs rflags rsp ss
    rax*:      uint64
    rbx*:      uint64
    rcx*:      uint64
    rdx*:      uint64
    rsi*:      uint64
    rdi*:      uint64
    rbp*:      uint64
    r8*:       uint64
    r9*:       uint64
    r10*:      uint64
    r11*:      uint64
    r12*:      uint64
    r13*:      uint64
    r14*:      uint64
    r15*:      uint64
    vectorNum*: uint64       ## Interrupt/exception vector number (pushed second)
    errorCode*: uint64       ## Error code pushed first (or fake 0)
    rip*:      uint64        ## CPU interrupt frame: instruction pointer
    cs*:       uint64        ## Code segment (64-bit frame uses 8-byte slots)
    rflags*:   uint64        ## CPU flags
    rsp*:      uint64        ## Stack pointer at time of interrupt
    ss*:       uint64        ## Stack segment

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
  entry.offsetHigh = uint32((offset shr 32) and 0xFFFFFFFF'u64)
  entry.selector = selector
  entry.ist = ist
  entry.flags = flags
  entry.reserved = 0

# ── ISR entry stubs from boot_asm.S ──────────────────────────────────────────
# Forward declarations for all 48 ISR entry stubs (exceptions 0-31, IRQs 32-47)
proc isr_entry_0()  {.importc, cdecl.}
proc isr_entry_1()  {.importc, cdecl.}
proc isr_entry_2()  {.importc, cdecl.}
proc isr_entry_3()  {.importc, cdecl.}
proc isr_entry_4()  {.importc, cdecl.}
proc isr_entry_5()  {.importc, cdecl.}
proc isr_entry_6()  {.importc, cdecl.}
proc isr_entry_7()  {.importc, cdecl.}
proc isr_entry_8()  {.importc, cdecl.}
proc isr_entry_9()  {.importc, cdecl.}
proc isr_entry_10() {.importc, cdecl.}
proc isr_entry_11() {.importc, cdecl.}
proc isr_entry_12() {.importc, cdecl.}
proc isr_entry_13() {.importc, cdecl.}
proc isr_entry_14() {.importc, cdecl.}
proc isr_entry_15() {.importc, cdecl.}
proc isr_entry_16() {.importc, cdecl.}
proc isr_entry_17() {.importc, cdecl.}
proc isr_entry_18() {.importc, cdecl.}
proc isr_entry_19() {.importc, cdecl.}
proc isr_entry_20() {.importc, cdecl.}
proc isr_entry_21() {.importc, cdecl.}
proc isr_entry_22() {.importc, cdecl.}
proc isr_entry_23() {.importc, cdecl.}
proc isr_entry_24() {.importc, cdecl.}
proc isr_entry_25() {.importc, cdecl.}
proc isr_entry_26() {.importc, cdecl.}
proc isr_entry_27() {.importc, cdecl.}
proc isr_entry_28() {.importc, cdecl.}
proc isr_entry_29() {.importc, cdecl.}
proc isr_entry_30() {.importc, cdecl.}
proc isr_entry_31() {.importc, cdecl.}
proc isr_entry_32() {.importc, cdecl.}
proc isr_entry_33() {.importc, cdecl.}
proc isr_entry_34() {.importc, cdecl.}
proc isr_entry_35() {.importc, cdecl.}
proc isr_entry_36() {.importc, cdecl.}
proc isr_entry_37() {.importc, cdecl.}
proc isr_entry_38() {.importc, cdecl.}
proc isr_entry_39() {.importc, cdecl.}
proc isr_entry_40() {.importc, cdecl.}
proc isr_entry_41() {.importc, cdecl.}
proc isr_entry_42() {.importc, cdecl.}
proc isr_entry_43() {.importc, cdecl.}
proc isr_entry_44() {.importc, cdecl.}
proc isr_entry_45() {.importc, cdecl.}
proc isr_entry_46() {.importc, cdecl.}
proc isr_entry_47() {.importc, cdecl.}

proc isrAddr(p: proc() {.cdecl.}): uint64 {.inline.} =
  ## Extract the raw function pointer address from a cdecl proc.
  cast[uint64](p)

# Table of all entry stub addresses (indexed by vector)
let isrEntries: array[48, uint64] = [
  isrAddr(isr_entry_0),  isrAddr(isr_entry_1),
  isrAddr(isr_entry_2),  isrAddr(isr_entry_3),
  isrAddr(isr_entry_4),  isrAddr(isr_entry_5),
  isrAddr(isr_entry_6),  isrAddr(isr_entry_7),
  isrAddr(isr_entry_8),  isrAddr(isr_entry_9),
  isrAddr(isr_entry_10), isrAddr(isr_entry_11),
  isrAddr(isr_entry_12), isrAddr(isr_entry_13),
  isrAddr(isr_entry_14), isrAddr(isr_entry_15),
  isrAddr(isr_entry_16), isrAddr(isr_entry_17),
  isrAddr(isr_entry_18), isrAddr(isr_entry_19),
  isrAddr(isr_entry_20), isrAddr(isr_entry_21),
  isrAddr(isr_entry_22), isrAddr(isr_entry_23),
  isrAddr(isr_entry_24), isrAddr(isr_entry_25),
  isrAddr(isr_entry_26), isrAddr(isr_entry_27),
  isrAddr(isr_entry_28), isrAddr(isr_entry_29),
  isrAddr(isr_entry_30), isrAddr(isr_entry_31),
  isrAddr(isr_entry_32), isrAddr(isr_entry_33),
  isrAddr(isr_entry_34), isrAddr(isr_entry_35),
  isrAddr(isr_entry_36), isrAddr(isr_entry_37),
  isrAddr(isr_entry_38), isrAddr(isr_entry_39),
  isrAddr(isr_entry_40), isrAddr(isr_entry_41),
  isrAddr(isr_entry_42), isrAddr(isr_entry_43),
  isrAddr(isr_entry_44), isrAddr(isr_entry_45),
  isrAddr(isr_entry_46), isrAddr(isr_entry_47),
]

proc loadIdt*(mgr: InterruptManager) {.inline.} =
  ## Load IDT into IDTR (lidt instruction).
  let limit = uint16(256 * sizeof(IdtEntry) - 1)
  lidt(addr mgr.idt[0], limit)

proc initializeIdt*(manager: InterruptManager, kernelCodeSelector: uint16): Result[void, ExceptionError] =
  ## Initialize IDT with real ISR stub addresses.
  manager.lock.init()

  # Clear all handlers
  for i in 0..<256:
    manager.handlers[i] = nil

  let flags = IDT_PRESENT or IDT_DPL_KERNEL or IDT_INTERRUPT_GATE

  # Wire ISR entry stubs for vectors 0-47
  for i in 0..<48:
    setIdtEntry(manager.idt[i], isrEntries[i], kernelCodeSelector, flags)

  # Fill remaining entries 48-255 with zeroed-but-present entries (no valid offset)
  for i in 48..<256:
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
  let vec = int(ctx.vectorNum)
  if vec >= 256:
    return err(eeInvalidVector)

  manager.lock.acquire()
  let handler = manager.handlers[vec]
  manager.lock.release()

  if handler == nil:
    return err(eeHandlerNotSet)

  # Update statistics
  inc manager.totalInterrupts
  if vec < 32:
    inc manager.exceptionCount[vec]
  elif vec >= IRQ_OFFSET:
    let irqNum = vec - IRQ_OFFSET
    if irqNum < 16:
      inc manager.irqCount[irqNum]

  # Call handler
  handler(ctx)
  ok()

proc nimInterruptDispatch*(ctx: ptr ExceptionContext) {.exportc, cdecl.} =
  ## Called from isr_common_stub. Dispatches to registered Nim handler.
  let mgr = getInterruptManager()
  if mgr != nil:
    discard mgr.dispatchException(ctx)

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
  ?manager.registerExceptionHandler(EX_DIVIDE_ERROR, defaultDivideErrorHandler)
  ?manager.registerExceptionHandler(EX_PAGE_FAULT, defaultPageFaultHandler)
  ?manager.registerExceptionHandler(EX_GENERAL_PROTECTION, defaultGeneralProtectionHandler)
  ?manager.registerExceptionHandler(EX_DOUBLE_FAULT, defaultDoubleFaultHandler)
  ok()

proc initInterruptSystem*(kernelCodeSelector: uint16): Result[void, ExceptionError] =
  ## Initialize the global interrupt system
  globalInterruptManager = newInterruptManager()
  ?globalInterruptManager.initializeIdt(kernelCodeSelector)
  ?globalInterruptManager.installDefaultHandlers()
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
