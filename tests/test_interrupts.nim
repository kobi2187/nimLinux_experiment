# SPDX-License-Identifier: GPL-2.0
## Tests for Interrupt & Exception System Component

import unittest
import ../kern/interrupts
import ../core/types

suite "Interrupt System - Component Tests":

  test "Exception constants are valid":
    check EX_DIVIDE_ERROR == 0
    check EX_DOUBLE_FAULT == 8
    check EX_PAGE_FAULT == 14
    check EX_GENERAL_PROTECTION == 13

  test "IRQ offset is correct":
    check IRQ_OFFSET == 32
    check IRQ_TIMER == 32
    check IRQ_KEYBOARD == 33

  test "IDT flags constants":
    check IDT_PRESENT == 0x80'u8
    check IDT_DPL_KERNEL == 0x00'u8
    check IDT_DPL_USER == 0x60'u8
    check IDT_TRAP_GATE == 0x0F'u8
    check IDT_INTERRUPT_GATE == 0x0E'u8

  test "ExceptionContext size is reasonable":
    check sizeof(ExceptionContext) > 0
    check sizeof(ExceptionContext) <= 512  # Should fit on stack

  test "IdtEntry size matches x86_64 spec":
    # IDT entries are 16 bytes
    check sizeof(IdtEntry) == 16

  test "IdtRegister layout":
    check sizeof(IdtRegister) == 10  # 2 bytes limit + 8 bytes offset

suite "Interrupt System - IDT Setup":

  test "Set IDT entry":
    var entry: IdtEntry
    let offset = uint64(0x12345678ABCDEF00)
    let selector = uint16(0x08)
    let flags = uint8(IDT_PRESENT or IDT_INTERRUPT_GATE)

    entry.setIdtEntry(offset, selector, flags)

    check entry.offsetLow == uint16(0xEF00)
    check entry.offsetMid == uint16(0xABCD)
    check entry.offsetHigh == uint32(0x12345678)
    check entry.selector == 0x08
    check entry.flags == flags
    check entry.reserved == 0

  test "IDT entry offset reconstruction":
    var entry: IdtEntry
    let originalOffset = uint64(0xFFFF800000000000)  # Canonical kernel address

    entry.setIdtEntry(originalOffset, 0x08, IDT_PRESENT)

    # Reconstruct offset
    let reconstructed = uint64(entry.offsetLow) or
                       (uint64(entry.offsetMid) shl 16) or
                       (uint64(entry.offsetHigh) shl 32)

    check reconstructed == originalOffset

  test "Create interrupt manager":
    let manager = newInterruptManager()
    check manager != nil
    check manager.totalInterrupts == 0

  test "Initialize IDT":
    let manager = newInterruptManager()
    let result = manager.initializeIdt(0x08)

    check result.isOk()
    # Check that entries are properly initialized
    for i in 0..<256:
      check manager.idt[i].flags != 0
      check manager.idt[i].selector == 0x08

suite "Interrupt System - Handler Management":

  test "Register exception handler":
    let manager = newInterruptManager()
    var called = false

    proc testHandler(ctx: ptr ExceptionContext) =
      called = true

    let result = manager.registerExceptionHandler(EX_DIVIDE_ERROR, testHandler)
    check result.isOk()
    check manager.handlers[EX_DIVIDE_ERROR] != nil

  test "Register with invalid vector":
    let manager = newInterruptManager()

    proc dummyHandler(ctx: ptr ExceptionContext) =
      discard

    let result = manager.registerExceptionHandler(256, dummyHandler)
    check result.isErr()
    check result.error() == eeInvalidVector

  test "Register nil handler":
    let manager = newInterruptManager()
    let result = manager.registerExceptionHandler(EX_PAGE_FAULT, nil)
    check result.isErr()
    check result.error() == eeInvalidHandler

  test "Register duplicate handler":
    let manager = newInterruptManager()

    proc handler1(ctx: ptr ExceptionContext) = discard
    proc handler2(ctx: ptr ExceptionContext) = discard

    discard manager.registerExceptionHandler(EX_DIVIDE_ERROR, handler1)
    let result = manager.registerExceptionHandler(EX_DIVIDE_ERROR, handler2)

    check result.isErr()
    check result.error() == eeAlreadyRegistered

  test "Unregister exception handler":
    let manager = newInterruptManager()

    proc testHandler(ctx: ptr ExceptionContext) = discard

    discard manager.registerExceptionHandler(EX_PAGE_FAULT, testHandler)
    let result = manager.unregisterExceptionHandler(EX_PAGE_FAULT)

    check result.isOk()
    check manager.handlers[EX_PAGE_FAULT] == nil

  test "Unregister with invalid vector":
    let manager = newInterruptManager()
    let result = manager.unregisterExceptionHandler(300)

    check result.isErr()
    check result.error() == eeInvalidVector

suite "Interrupt System - Exception Dispatch":

  test "Dispatch registered exception":
    let manager = newInterruptManager()
    var handlerCalled = false

    proc testHandler(ctx: ptr ExceptionContext) =
      handlerCalled = true

    discard manager.registerExceptionHandler(EX_DIVIDE_ERROR, testHandler)

    var ctx: ExceptionContext
    ctx.vectorNum = EX_DIVIDE_ERROR
    ctx.isException = true
    ctx.rip = 0x1000
    ctx.rax = 0x5000

    let result = manager.dispatchException(addr ctx)
    check result.isOk()
    check handlerCalled == true

  test "Dispatch unregistered exception":
    let manager = newInterruptManager()

    var ctx: ExceptionContext
    ctx.vectorNum = EX_DIVIDE_ERROR
    ctx.isException = true

    let result = manager.dispatchException(addr ctx)
    check result.isErr()
    check result.error() == eeHandlerNotSet

  test "Dispatch with invalid vector":
    let manager = newInterruptManager()

    var ctx: ExceptionContext
    ctx.vectorNum = 300
    ctx.isException = true

    let result = manager.dispatchException(addr ctx)
    check result.isErr()
    check result.error() == eeInvalidVector

  test "Statistics tracking - exceptions":
    let manager = newInterruptManager()

    proc dummyHandler(ctx: ptr ExceptionContext) = discard

    discard manager.registerExceptionHandler(EX_PAGE_FAULT, dummyHandler)

    var ctx: ExceptionContext
    ctx.vectorNum = EX_PAGE_FAULT
    ctx.isException = true

    discard manager.dispatchException(addr ctx)
    discard manager.dispatchException(addr ctx)

    check manager.totalInterrupts == 2
    check manager.exceptionCount[EX_PAGE_FAULT] == 2

  test "Statistics tracking - IRQs":
    let manager = newInterruptManager()

    proc dummyHandler(ctx: ptr ExceptionContext) = discard

    discard manager.registerExceptionHandler(IRQ_TIMER, dummyHandler)

    var ctx: ExceptionContext
    ctx.vectorNum = IRQ_TIMER
    ctx.isException = false

    discard manager.dispatchException(addr ctx)

    check manager.totalInterrupts == 1
    check manager.irqCount[0] == 1  # IRQ 0 = timer

suite "Interrupt System - Default Handlers":

  test "Install default handlers":
    let manager = newInterruptManager()
    let result = manager.installDefaultHandlers()

    check result.isOk()
    check manager.handlers[EX_DIVIDE_ERROR] != nil
    check manager.handlers[EX_PAGE_FAULT] != nil
    check manager.handlers[EX_GENERAL_PROTECTION] != nil
    check manager.handlers[EX_DOUBLE_FAULT] != nil

suite "Interrupt System - Exception Naming":

  test "Get exception names":
    check getExceptionName(EX_DIVIDE_ERROR) == "Divide Error"
    check getExceptionName(EX_PAGE_FAULT) == "Page Fault"
    check getExceptionName(EX_DOUBLE_FAULT) == "Double Fault"
    check getExceptionName(EX_GENERAL_PROTECTION) == "General Protection Fault"
    check getExceptionName(EX_INVALID_OPCODE) == "Invalid Opcode"
    check getExceptionName(EX_BREAKPOINT) == "Breakpoint"

  test "Unknown exception returns generic name":
    let name = getExceptionName(255)
    check "Unknown" in name

suite "Interrupt System - Statistics":

  test "Get interrupt statistics":
    let manager = newInterruptManager()

    proc handler1(ctx: ptr ExceptionContext) = discard
    proc handler2(ctx: ptr ExceptionContext) = discard

    discard manager.registerExceptionHandler(EX_DIVIDE_ERROR, handler1)
    discard manager.registerExceptionHandler(IRQ_TIMER, handler2)

    var ctx1: ExceptionContext
    ctx1.vectorNum = EX_DIVIDE_ERROR
    ctx1.isException = true

    var ctx2: ExceptionContext
    ctx2.vectorNum = IRQ_TIMER
    ctx2.isException = false

    discard manager.dispatchException(addr ctx1)
    discard manager.dispatchException(addr ctx2)

    let stats = manager.getInterruptStats()
    check "Interrupt Statistics" in stats
    check "Total Interrupts: 2" in stats

  test "Context frame layout":
    var ctx: ExceptionContext
    ctx.rax = 0x1111
    ctx.rbx = 0x2222
    ctx.rip = 0x3333
    ctx.vectorNum = EX_PAGE_FAULT
    ctx.errorCode = 0x4444
    ctx.hasErrorCode = true

    check ctx.rax == 0x1111
    check ctx.rbx == 0x2222
    check ctx.rip == 0x3333
    check ctx.vectorNum == EX_PAGE_FAULT
    check ctx.errorCode == 0x4444
    check ctx.hasErrorCode == true

  test "Multiple exception dispatch":
    let manager = newInterruptManager()
    var dispatchCount = 0

    proc countingHandler(ctx: ptr ExceptionContext) =
      inc dispatchCount

    discard manager.registerExceptionHandler(EX_PAGE_FAULT, countingHandler)

    for i in 0..<5:
      var ctx: ExceptionContext
      ctx.vectorNum = EX_PAGE_FAULT
      ctx.isException = true
      discard manager.dispatchException(addr ctx)

    check dispatchCount == 5
    check manager.exceptionCount[EX_PAGE_FAULT] == 5
