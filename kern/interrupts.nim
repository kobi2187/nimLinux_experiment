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
import ../core/backtrace

# ═══════════════════════════════════════════════════════════════════════════
# Exception Context
# ═══════════════════════════════════════════════════════════════════════════

type
  ExceptionContext* {.packed.} = object
    ## CPU context saved on exception.
    ## Field order MUST match the assembly push sequence in isr_common_stub exactly.
    ##
    ## Stack layout at nimInterruptDispatch entry (RSP → r15, low addr first).
    ## isr_common_stub pushes rax first and r15 last, so r15 is at the LOWEST
    ## address (this order was once declared reversed: every GPR read back as
    ## a different register — ctx.rbp was r9).
    ##   [pushed by isr_common_stub]  r15 r14 .. r8 rbp rdi rsi rdx rcx rbx rax
    ##   [pushed by entry stub]       vectorNum  errorCode
    ##   [pushed by CPU on interrupt] rip cs rflags rsp ss
    r15*:      uint64
    r14*:      uint64
    r13*:      uint64
    r12*:      uint64
    r11*:      uint64
    r10*:      uint64
    r9*:       uint64
    r8*:       uint64
    rbp*:      uint64
    rdi*:      uint64
    rsi*:      uint64
    rdx*:      uint64
    rcx*:      uint64
    rbx*:      uint64
    rax*:      uint64
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

# The layout is a contract with isr_common_stub (arch/x86_64/boot_asm.S).
static:
  doAssert offsetOf(ExceptionContext, r15) == 0
  doAssert offsetOf(ExceptionContext, rax) == 14 * 8
  doAssert offsetOf(ExceptionContext, vectorNum) == 15 * 8
  doAssert offsetOf(ExceptionContext, rip) == 17 * 8

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
  ## Register handler for exception vector (0-255).
  ##
  ## Returns:
  ## - Ok() if handler registered successfully
  ## - eeInvalidVector if vector >= 256
  ## - eeInvalidHandler if handler is nil
  ## - eeAlreadyRegistered if handler already set for this vector
  if vector >= 256:
    return err(eeInvalidVector)

  if handler == nil:
    return err(eeInvalidHandler)

  manager.lock.acquire()
  defer: manager.lock.release()

  doAssert int(vector) < manager.handlers.len, "handler array bounds"

  if manager.handlers[vector] != nil:
    return err(eeAlreadyRegistered)

  manager.handlers[vector] = handler
  ok()

proc unregisterExceptionHandler*(manager: InterruptManager, vector: uint32): Result[void, ExceptionError] =
  ## Unregister handler for exception vector.
  ##
  ## Safe to call even if no handler registered (no-op in that case).
  if vector >= 256:
    return err(eeInvalidVector)

  manager.lock.acquire()
  defer: manager.lock.release()

  doAssert int(vector) < manager.handlers.len, "handler array bounds"
  manager.handlers[vector] = nil
  ok()

# ═══════════════════════════════════════════════════════════════════════════
# Exception Dispatch
# ═══════════════════════════════════════════════════════════════════════════

proc dispatchException*(manager: InterruptManager, ctx: ptr ExceptionContext): Result[void, ExceptionError] =
  ## Dispatch exception to registered handler.
  ##
  ## Context is passed from CPU exception frame or interrupt stub.
  ## If no handler registered, returns eeHandlerNotSet.
  doAssert ctx != nil, "exception context cannot be nil"

  let vec = int(ctx.vectorNum)
  doAssert vec >= 0 and vec < 256, "vector out of range"

  if vec >= 256:
    return err(eeInvalidVector)

  manager.lock.acquire()
  doAssert vec < manager.handlers.len, "handler array bounds"
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

proc fatalExceptionHandler*(ctx: ptr ExceptionContext)   # crash report, below

proc nimInterruptDispatch*(ctx: ptr ExceptionContext) {.exportc, cdecl.} =
  ## Called from isr_common_stub. Dispatches to registered Nim handler.
  let mgr = getInterruptManager()
  if mgr != nil:
    let r = mgr.dispatchException(ctx)
    if r.isErr and ctx.vectorNum < 32:
      fatalExceptionHandler(ctx)

# ═══════════════════════════════════════════════════════════════════════════
# Default Exception Handlers
# ═══════════════════════════════════════════════════════════════════════════

const ExceptionNames: array[32, cstring] = [
  "Divide Error", "Debug", "NMI", "Breakpoint", "Overflow", "Bound Range",
  "Invalid Opcode", "Device Not Available", "Double Fault", "Coprocessor Overrun",
  "Invalid TSS", "Segment Not Present", "Stack-Segment Fault",
  "General Protection Fault", "Page Fault", "Reserved", "x87 FP Error",
  "Alignment Check", "Machine Check", "SIMD FP Error", "Virtualization",
  "Control Protection", "Reserved", "Reserved", "Reserved", "Reserved",
  "Reserved", "Reserved", "Hypervisor Injection", "VMM Communication",
  "Security", "Reserved"]

proc putReg(name: cstring; v: uint64) =
  defaultSerial.putString(name)
  defaultSerial.putString("=0x")
  defaultSerial.putHex(v)

type
  UserFaultKill* = proc() {.nimcall.}
    ## Ends the current task for good (never returns). Set by the task layer.
  UserStackBounds* = proc(): tuple[lo, hi: uint64] {.nimcall.}
    ## Memory the current user task may own — bounds the backtrace walk.

var
  userFaultKill*: UserFaultKill
  userStackBounds*: UserStackBounds

proc printRegisters(ctx: ptr ExceptionContext) =
  putReg("err", ctx.errorCode); putReg("  cr2", readCr2()); putReg("  cr3", readCr3())
  defaultSerial.putChar('\n')
  putReg("rip", ctx.rip); putReg("  rsp", ctx.rsp); putReg("  rbp", ctx.rbp)
  putReg("  rflags", ctx.rflags); defaultSerial.putChar('\n')
  putReg("rax", ctx.rax); putReg("  rbx", ctx.rbx); putReg("  rcx", ctx.rcx)
  putReg("  rdx", ctx.rdx); defaultSerial.putChar('\n')
  putReg("rsi", ctx.rsi); putReg("  rdi", ctx.rdi); putReg("  r8", ctx.r8)
  putReg("  r9", ctx.r9); defaultSerial.putChar('\n')
  putReg("r10", ctx.r10); putReg("  r11", ctx.r11); putReg("  r12", ctx.r12)
  putReg("  r13", ctx.r13); defaultSerial.putChar('\n')
  putReg("r14", ctx.r14); putReg("  r15", ctx.r15); putReg("  cs", ctx.cs)
  putReg("  ss", ctx.ss); defaultSerial.putChar('\n')

proc printCrashReport(ctx: ptr ExceptionContext; user: bool) =
  ## Vector, registers and a frame-pointer backtrace (tools/symbolize.py
  ## names the frames; --app for a user task).
  defaultSerial.putString("\n=== CPU EXCEPTION ")
  defaultSerial.putInt(int64(ctx.vectorNum))
  defaultSerial.putString(" (")
  defaultSerial.putString(ExceptionNames[int(ctx.vectorNum and 31)])
  defaultSerial.putString(if user: ") in USER mode ===\n" else: ") in kernel mode ===\n")
  printRegisters(ctx)
  if user and userStackBounds != nil:
    let b = userStackBounds()
    printBacktrace(ctx.rip, ctx.rbp, b.lo, b.hi)
  elif user:
    printBacktrace(ctx.rip, 0'u64)          # bounds unknown: don't walk user memory
  else:
    printBacktrace(ctx.rip, ctx.rbp)

proc fatalExceptionHandler*(ctx: ptr ExceptionContext) =
  ## A fault in a user task kills that task — the kernel's own state is
  ## intact, so everything else keeps running. A fault in kernel mode means
  ## shared kernel state may be corrupt: report and halt. Returning instead
  ## would iretq onto the faulting instruction and loop.
  {.emit: "asm volatile(\"cli\");".}
  let user = (ctx.cs and 3) == 3
  printCrashReport(ctx, user)
  if user and userFaultKill != nil:
    userFaultKill()                         # never returns
  defaultSerial.putString("=== halted (symbolize: tools/symbolize.py <serial log>) ===\n")
  while true:
    {.emit: "asm volatile(\"cli; hlt\");".}

# ═══════════════════════════════════════════════════════════════════════════
# Initialization Utilities
# ═══════════════════════════════════════════════════════════════════════════

proc installDefaultHandlers*(manager: InterruptManager): Result[void, ExceptionError] =
  ## Install default handlers for common exceptions
  ## Every CPU exception except the debug traps (#DB, NMI, #BP) is fatal.
  for v in 0'u32 ..< 32'u32:
    if int(v) notin [EX_DEBUG, EX_NMI, EX_BREAKPOINT]:
      ?manager.registerExceptionHandler(v, fatalExceptionHandler)
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
  var stats = "Interrupt Statistics:\n"
  stats &= "  Total Interrupts: " & $manager.totalInterrupts & "\n"
  stats &= "  Exceptions:\n"

  for i in 0..<32:
    if manager.exceptionCount[i] > 0:
      stats &= "    Vector " & $i & ": " & $manager.exceptionCount[i] & "\n"

  stats &= "  IRQs:\n"
  for i in 0..<16:
    if manager.irqCount[i] > 0:
      stats &= "    IRQ " & $i & ": " & $manager.irqCount[i] & "\n"

  stats

proc getExceptionName*(vector: uint32): string =
  ## Get human-readable exception name
  case vector
  of EX_DIVIDE_ERROR:          "Divide Error"
  of EX_DEBUG:                 "Debug"
  of EX_NMI:                   "NMI"
  of EX_BREAKPOINT:            "Breakpoint"
  of EX_OVERFLOW:              "Overflow"
  of EX_BOUND_RANGE:           "Bound Range Exceeded"
  of EX_INVALID_OPCODE:        "Invalid Opcode"
  of EX_DEVICE_NOT_AVAILABLE:  "Device Not Available"
  of EX_DOUBLE_FAULT:          "Double Fault"
  of EX_COPROC_SEGMENT:        "Coprocessor Segment Overrun"
  of EX_INVALID_TSS:           "Invalid TSS"
  of EX_SEGMENT_NOT_PRESENT:   "Segment Not Present"
  of EX_STACK_FAULT:           "Stack Fault"
  of EX_GENERAL_PROTECTION:    "General Protection Fault"
  of EX_PAGE_FAULT:            "Page Fault"
  of EX_FLOAT_EXCEPTION:       "Floating Point Exception"
  of EX_ALIGNMENT_CHECK:       "Alignment Check"
  of EX_MACHINE_CHECK:         "Machine Check"
  of EX_SIMD_EXCEPTION:        "SIMD Exception"
  else:                        "Unknown Exception"
