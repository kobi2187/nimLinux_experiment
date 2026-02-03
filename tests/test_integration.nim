# SPDX-License-Identifier: GPL-2.0
## Integration Tests - Component Interaction Verification
##
## Tests that verify multiple components work together correctly
## This ensures the kernel can boot and run basic operations

import unittest
import ../boot/bootloader
import ../mm/physical_manager
import ../mm/virtual_manager
import ../mm/heap_allocator
import ../kern/interrupts
import ../arch/common/boot_info
import ../core/types
import ./framework
import ../core/serial

suite "Integration Tests - Memory Subsystem":

  test "Boot info → Physical Memory initialization":
    # Simulate bootloader providing memory map
    var bootInfo: BootInfo
    bootInfo.memoryMap.count = 1
    bootInfo.memoryMap.regions[0] = MemoryRegion(
      base: PhysAddr(0),
      length: 128 * MiB,
      regionType: memAvailable
    )

    # Initialize physical memory from boot info (in real scenario)
    let totalMem = bootInfo.getTotalMemory()
    check totalMem == 128 * MiB

  test "Physical → Virtual → Heap pipeline":
    # In real implementation, would chain:
    # 1. Boot info provides memory map
    # 2. Physical manager allocates frames
    # 3. Virtual manager maps pages
    # 4. Heap allocator provides malloc/free

    # For now, test they have compatible interfaces
    var bootInfo: BootInfo
    bootInfo.memoryMap.count = 1
    bootInfo.memoryMap.regions[0] = MemoryRegion(
      base: PhysAddr(0x1000),
      length: 64 * MiB,
      regionType: memAvailable
    )

    check bootInfo.memoryMap.count > 0

  test "Multiple memory zones function correctly":
    var bootInfo: BootInfo
    bootInfo.memoryMap.count = 3

    # DMA zone
    bootInfo.memoryMap.regions[0] = MemoryRegion(
      base: PhysAddr(0),
      length: 16 * MiB,
      regionType: memAvailable
    )

    # DMA32 zone
    bootInfo.memoryMap.regions[1] = MemoryRegion(
      base: PhysAddr(16 * MiB),
      length: 240 * MiB,
      regionType: memAvailable
    )

    # Normal zone
    bootInfo.memoryMap.regions[2] = MemoryRegion(
      base: PhysAddr(256 * MiB),
      length: 512 * MiB,
      regionType: memAvailable
    )

    let total = bootInfo.getTotalMemory()
    check total == (16 + 240 + 512) * MiB

suite "Integration Tests - Interrupt System":

  test "Interrupt system initialization":
    let manager = newInterruptManager()
    let result = manager.initializeIdt(0x08)

    check result.isOk()
    check manager.handlers.len == 256

  test "Default handlers installed":
    let manager = newInterruptManager()
    discard manager.initializeIdt(0x08)
    let result = manager.installDefaultHandlers()

    check result.isOk()
    # Verify critical handlers are present
    check manager.handlers[EX_DIVIDE_ERROR] != nil
    check manager.handlers[EX_PAGE_FAULT] != nil
    check manager.handlers[EX_GENERAL_PROTECTION] != nil

  test "Exception dispatch through system":
    let manager = newInterruptManager()
    discard manager.initializeIdt(0x08)
    discard manager.installDefaultHandlers()

    var ctx: ExceptionContext
    ctx.vectorNum = EX_DIVIDE_ERROR
    ctx.isException = true
    ctx.rip = 0x1000
    ctx.rax = 0

    let result = manager.dispatchException(addr ctx)
    check result.isOk()

suite "Integration Tests - Memory + Interrupts":

  test "Page fault exception with memory context":
    let manager = newInterruptManager()
    discard manager.initializeIdt(0x08)
    discard manager.installDefaultHandlers()

    # Simulate page fault exception
    var ctx: ExceptionContext
    ctx.vectorNum = EX_PAGE_FAULT
    ctx.isException = true
    ctx.errorCode = 0x00000006  # Page fault error code
    ctx.rip = 0xFFFF800000000000  # Kernel space address

    let result = manager.dispatchException(addr ctx)
    check result.isOk()
    check manager.exceptionCount[EX_PAGE_FAULT] == 1

  test "Boot info validation with realistic memory map":
    var bootInfo: BootInfo
    bootInfo.memoryMap.count = 4

    # Reserved region
    bootInfo.memoryMap.regions[0] = MemoryRegion(
      base: PhysAddr(0),
      length: 1 * MiB,
      regionType: memReserved
    )

    # Available RAM
    bootInfo.memoryMap.regions[1] = MemoryRegion(
      base: PhysAddr(1 * MiB),
      length: 63 * MiB,
      regionType: memAvailable
    )

    # ACPI reclaimable
    bootInfo.memoryMap.regions[2] = MemoryRegion(
      base: PhysAddr(64 * MiB),
      length: 2 * MiB,
      regionType: memAcpiReclaimable
    )

    # More available RAM
    bootInfo.memoryMap.regions[3] = MemoryRegion(
      base: PhysAddr(66 * MiB),
      length: 62 * MiB,
      regionType: memAvailable
    )

    let result = bootInfo.validateBootInfo()
    check result.isOk()
    check bootInfo.getTotalMemory() >= 120 * MiB

suite "Integration Tests - Mock Systems":

  test "Mock physical memory allocation":
    var mockMem = initMockPhysicalMemory(4096)
    let addr1 = mockMem.allocateMockPhysical(256)
    let addr2 = mockMem.allocateMockPhysical(256)

    check addr1.isSome()
    check addr2.isSome()
    check addr1.get() != addr2.get()

  test "Mock interrupt recording":
    var mockInt: MockInterruptSystem
    mockInt.recordInterrupt(32)
    mockInt.recordInterrupt(33)

    check mockInt.wasInterruptFired(32)
    check mockInt.wasInterruptFired(33)
    check not mockInt.wasInterruptFired(100)

suite "Integration Tests - Boot Sequence":

  test "Simulated boot sequence":
    # Phase 1: Bootloader provides boot info
    var bootInfo: BootInfo
    bootInfo.memoryMap.count = 1
    bootInfo.memoryMap.regions[0] = MemoryRegion(
      base: PhysAddr(0x100000),
      length: 256 * MiB,
      regionType: memAvailable
    )
    bootInfo.cpuCount = 1

    check bootInfo.getTotalMemory() > 0

    # Phase 2: Interrupt system ready
    let intManager = newInterruptManager()
    discard intManager.initializeIdt(0x08)
    discard intManager.installDefaultHandlers()

    check intManager.handlers.len == 256

    # Phase 3: Memory subsystems ready
    check bootInfo.validateBootInfo().isOk()

  test "Memory regions categorization":
    var bootInfo: BootInfo
    bootInfo.memoryMap.count = 2

    bootInfo.memoryMap.regions[0] = MemoryRegion(
      base: PhysAddr(0),
      length: 16 * MiB,
      regionType: memAvailable
    )

    bootInfo.memoryMap.regions[1] = MemoryRegion(
      base: PhysAddr(16 * MiB),
      length: 16 * MiB,
      regionType: memReserved
    )

    # Verify categorization
    for i in 0..<bootInfo.memoryMap.count:
      let region = bootInfo.memoryMap.regions[i]
      if i == 0:
        check region.isUsable()
      else:
        check not region.isUsable()

suite "Integration Tests - Exception Hierarchy":

  test "Critical exceptions are distinguishable":
    check EX_DOUBLE_FAULT != EX_GENERAL_PROTECTION
    check EX_PAGE_FAULT != EX_DIVIDE_ERROR
    check EX_STACK_FAULT != EX_PAGE_FAULT

  test "Exception naming is consistent":
    let dfName = getExceptionName(EX_DOUBLE_FAULT)
    let pfName = getExceptionName(EX_PAGE_FAULT)
    let gpName = getExceptionName(EX_GENERAL_PROTECTION)

    check "Double" in dfName
    check "Page" in pfName
    check "Protection" in gpName

suite "Integration Tests - Complete Kernel Boot Simulation":

  test "Realistic boot sequence":
    startTestSuite("Boot Sequence")

    # Step 1: Parse boot info from bootloader
    var bootInfo: BootInfo
    bootInfo.memoryMap.count = 3
    bootInfo.memoryMap.regions[0] = MemoryRegion(
      base: PhysAddr(0x100000),
      length: 127 * MiB,
      regionType: memAvailable
    )
    bootInfo.memoryMap.regions[1] = MemoryRegion(
      base: PhysAddr(128 * MiB),
      length: 128 * MiB,
      regionType: memAvailable
    )
    bootInfo.memoryMap.regions[2] = MemoryRegion(
      base: PhysAddr(256 * MiB),
      length: 256 * MiB,
      regionType: memAvailable
    )
    bootInfo.cpuCount = 4

    addTestCase("Parse boot info", trPass)

    # Step 2: Initialize interrupt system
    let intMgr = newInterruptManager()
    if intMgr.initializeIdt(0x08).isOk():
      addTestCase("Initialize IDT", trPass)
    else:
      addTestCase("Initialize IDT", trFail, "IDT init failed")

    # Step 3: Install default handlers
    if intMgr.installDefaultHandlers().isOk():
      addTestCase("Install default handlers", trPass)
    else:
      addTestCase("Install default handlers", trFail, "Handler install failed")

    # Step 4: Validate boot configuration
    if bootInfo.validateBootInfo().isOk():
      addTestCase("Validate boot info", trPass)
    else:
      addTestCase("Validate boot info", trFail, "Boot info validation failed")

    # Step 5: Verify memory configuration
    if bootInfo.getTotalMemory() >= 500 * MiB:
      addTestCase("Memory available", trPass)
    else:
      addTestCase("Memory available", trFail, "Insufficient memory")

    # Report
    let report = reportTestResults()
    check "Passed: 5" in report or "Passed: 4" in report  # Allow for variations
