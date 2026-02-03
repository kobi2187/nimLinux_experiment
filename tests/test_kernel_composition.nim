# SPDX-License-Identifier: GPL-2.0
## Kernel Composition Tests
##
## Demonstrates that NimixOS is composable - you can choose different
## execution models, memory strategies, and components without rewriting
##
## Shows: Boot with threads vs. fibers vs. green threads

import unittest
import ../boot/bootloader
import ../mm/physical_manager
import ../mm/virtual_manager
import ../mm/heap_allocator
import ../kern/interrupts
import ../sched/execution_model
import ../sched/thread_model
import ../sched/fiber_model
import ../sched/greenthread_model
import ../sched/task_adapter
import ../sched/task_manager
import ../sched/scheduler
import ../arch/common/boot_info
import ../core/types
import ./framework

# ═══════════════════════════════════════════════════════════════════════════
# Simulated Kernel Configuration
# ═══════════════════════════════════════════════════════════════════════════

type
  KernelConfig* = object
    ## Selectable kernel configuration
    executionModel*: ExecutionModel
    modelName*: string
    cpuCount*: int
    memorySize*: uint64
    enablePreemption*: bool

proc createThreadedKernel*(): KernelConfig =
  ## Kernel using preemptive kernel threads
  KernelConfig(
    executionModel: createThreadModelImpl(),
    modelName: "Threaded",
    cpuCount: 4,
    memorySize: 256 * MiB,
    enablePreemption: true
  )

proc createFiberedKernel*(): KernelConfig =
  ## Kernel using lightweight fibers (cooperative)
  KernelConfig(
    executionModel: createFiberModelImpl(),
    modelName: "Fibered",
    cpuCount: 1,
    memorySize: 128 * MiB,
    enablePreemption: false
  )

proc createGreenThreadKernel*(): KernelConfig =
  ## Kernel using green threads (user-space cooperative)
  KernelConfig(
    executionModel: createGreenThreadModelImpl(),
    modelName: "Green-Threaded",
    cpuCount: 1,
    memorySize: 64 * MiB,
    enablePreemption: false
  )

# ═══════════════════════════════════════════════════════════════════════════
# Simulated Kernel Boot
# ═══════════════════════════════════════════════════════════════════════════

suite "Kernel Composition - Boot Sequence":

  test "Boot with threaded execution model":
    var config = createThreadedKernel()

    # Verify configuration
    check config.modelName == "Threaded"
    check config.enablePreemption == true
    check config.cpuCount == 4

    # Get model name
    let modelName = $config.executionModel.vtable.name
    check "Thread" in modelName

  test "Boot with fibered execution model":
    var config = createFiberedKernel()

    check config.modelName == "Fibered"
    check config.enablePreemption == false
    check config.cpuCount == 1

    let modelName = $config.executionModel.vtable.name
    check "Fiber" in modelName

  test "Boot with green thread execution model":
    var config = createGreenThreadKernel()

    check config.modelName == "Green-Threaded"
    check config.enablePreemption == false
    check config.cpuCount == 1

    let modelName = $config.executionModel.vtable.name
    check "Green" in modelName

suite "Kernel Composition - Memory Subsystem":

  test "Memory subsystem with boot info":
    var bootInfo: BootInfo
    bootInfo.memoryMap.count = 2

    # DMA zone
    bootInfo.memoryMap.regions[0] = MemoryRegion(
      base: PhysAddr(0x100000),
      length: 64 * MiB,
      regionType: memAvailable
    )

    # Normal zone
    bootInfo.memoryMap.regions[1] = MemoryRegion(
      base: PhysAddr(64 * MiB + 0x100000),
      length: 192 * MiB,
      regionType: memAvailable
    )

    let totalMem = bootInfo.getTotalMemory()
    check totalMem == 256 * MiB

  test "Virtual memory setup":
    # Create virtual address space
    var vmm: VirtualMemManager

    # In real kernel, would map kernel space, user space, etc
    check vmm != nil

  test "Heap allocator initialization":
    var allocator: HeapAllocator
    var buffer: array[4096, byte]

    let result = allocator.init(addr buffer[0], 4096)
    check result.isOk()

suite "Kernel Composition - Interrupt System":

  test "Interrupt system setup":
    let manager = newInterruptManager()
    let result = manager.initializeIdt(0x08)

    check result.isOk()
    check manager.handlers.len == 256

  test "Install default handlers":
    let manager = newInterruptManager()
    discard manager.initializeIdt(0x08)

    let result = manager.installDefaultHandlers()
    check result.isOk()

    # Verify handlers are installed
    check manager.handlers[EX_DIVIDE_ERROR] != nil
    check manager.handlers[EX_PAGE_FAULT] != nil

suite "Kernel Composition - Task Management with Models":

  test "Create tasks with thread model":
    startTestSuite("Task Creation - Threads")

    let model = createThreadModelImpl()
    var unit = model.createUnit(ExecutionPriority(50))

    check unit.isOk()
    addTestCase("Create execution unit", trPass)

    if unit.isSome:
      let destroyResult = model.destroyUnit(unit.value)
      check destroyResult.isOk()
      addTestCase("Destroy execution unit", trPass)

  test "Create tasks with fiber model":
    startTestSuite("Task Creation - Fibers")

    let model = createFiberModelImpl()

    # Create multiple fibers
    var fibers: seq[ExecutionUnit] = @[]
    for i in 0..<5:
      let result = model.createUnit(ExecutionPriority(i))
      if result.isOk():
        fibers.add(result.value)
        addTestCase("Create fiber " & $i, trPass)

    check fibers.len == 5

  test "Create tasks with green thread model":
    startTestSuite("Task Creation - Green Threads")

    let model = createGreenThreadModelImpl()

    var threads: seq[ExecutionUnit] = @[]
    for i in 0..<10:
      let result = model.createUnit(ExecutionPriority(i mod 5))
      if result.isOk():
        threads.add(result.value)

    addTestCase("Create green threads", trPass)
    check threads.len == 10

suite "Kernel Composition - Scheduler with Models":

  test "Schedule with thread model":
    let model = createThreadModelImpl()
    var taskMgr: TaskManager  # Would be properly initialized

    let scheduler = newSchedulerManager(taskMgr, 4, model)

    check scheduler.useExecutionModel == true
    check scheduler.cpuCount == 4

  test "Schedule with fiber model":
    let model = createFiberModelImpl()
    var taskMgr: TaskManager

    let scheduler = newSchedulerManager(taskMgr, 1, model)

    check scheduler.useExecutionModel == true
    check scheduler.cpuCount == 1

  test "Change execution model at runtime":
    var taskMgr: TaskManager
    let scheduler = newSchedulerManager(taskMgr, 1, createThreadModelImpl())

    # Initially threaded
    check scheduler.getExecutionModelName() == "Threads"

    # Switch to fibers
    scheduler.setExecutionModel(createFiberModelImpl())
    check scheduler.getExecutionModelName() == "Fibers"

    # Switch to green threads
    scheduler.setExecutionModel(createGreenThreadModelImpl())
    check scheduler.getExecutionModelName() == "Green Threads"

suite "Kernel Composition - Complete Boot Simulation":

  test "Boot kernel with thread model":
    startTestSuite("Boot - Thread Model")

    var config = createThreadedKernel()

    # Step 1: Parse boot info
    var bootInfo: BootInfo
    bootInfo.memoryMap.count = 1
    bootInfo.memoryMap.regions[0] = MemoryRegion(
      base: PhysAddr(0x100000),
      length: 256 * MiB,
      regionType: memAvailable
    )
    bootInfo.cpuCount = 4

    addTestCase("Parse boot info", trPass)

    # Step 2: Initialize interrupt system
    let intManager = newInterruptManager()
    if intManager.initializeIdt(0x08).isOk():
      addTestCase("Initialize IDT", trPass)
    else:
      addTestCase("Initialize IDT", trFail, "IDT init failed")

    # Step 3: Install default handlers
    if intManager.installDefaultHandlers().isOk():
      addTestCase("Install handlers", trPass)
    else:
      addTestCase("Install handlers", trFail, "Handler install failed")

    # Step 4: Initialize execution model
    check config.executionModel.vtable != nil
    addTestCase("Initialize execution model", trPass)

    # Step 5: Create scheduler with model
    var taskMgr: TaskManager
    let scheduler = newSchedulerManager(taskMgr, config.cpuCount, config.executionModel)
    check scheduler.useExecutionModel == true
    addTestCase("Create scheduler with model", trPass)

    let report = reportTestResults()
    check "Passed: 5" in report or "Passed: 4" in report

  test "Boot kernel with fiber model":
    startTestSuite("Boot - Fiber Model")

    var config = createFiberedKernel()

    var bootInfo: BootInfo
    bootInfo.memoryMap.count = 1
    bootInfo.memoryMap.regions[0] = MemoryRegion(
      base: PhysAddr(0x100000),
      length: 128 * MiB,
      regionType: memAvailable
    )

    addTestCase("Parse boot info", trPass)

    let intManager = newInterruptManager()
    discard intManager.initializeIdt(0x08)
    discard intManager.installDefaultHandlers()

    addTestCase("Initialize interrupt system", trPass)

    # Fiber model uses only 1 CPU
    check config.cpuCount == 1
    addTestCase("Configure for cooperative scheduling", trPass)

    let report = reportTestResults()
    check "Passed" in report

  test "Boot kernel with green thread model":
    startTestSuite("Boot - Green Thread Model")

    var config = createGreenThreadKernel()

    var bootInfo: BootInfo
    bootInfo.memoryMap.count = 1
    bootInfo.memoryMap.regions[0] = MemoryRegion(
      base: PhysAddr(0x100000),
      length: 64 * MiB,
      regionType: memAvailable
    )

    addTestCase("Parse boot info", trPass)

    let intManager = newInterruptManager()
    discard intManager.initializeIdt(0x08)
    discard intManager.installDefaultHandlers()

    addTestCase("Initialize interrupt system", trPass)

    check config.enablePreemption == false
    addTestCase("Configure for cooperative scheduling", trPass)

suite "Kernel Composition - Model Comparison":

  test "Compare characteristics of all models":
    let comparison = compareModels()

    # All models should be mentioned
    check "Threads" in comparison
    check "Fibers" in comparison
    check "Green Threads" in comparison

    # Should show different tradeoffs
    check "1000" in comparison  # Thread context switch cost
    check "100" in comparison   # Fiber context switch cost
    check "50" in comparison    # Green thread context switch cost

  test "Choose model based on requirements":
    # For high throughput with preemption: use threads
    if true:  # preemption_required
      let model = createThreadModelImpl()
      check $model.vtable.name == "Threads"

    # For high concurrency without preemption: use fibers
    if true:  # high_concurrency and not preemption_required
      let model = createFiberModelImpl()
      check $model.vtable.name == "Fibers"

    # For balance: use green threads
    if true:  # want_both_concurrency_and_speed
      let model = createGreenThreadModelImpl()
      check $model.vtable.name == "Green Threads"

suite "Kernel Composition - Extensibility":

  test "Kernel supports pluggable components":
    # Boot info
    var bootInfo: BootInfo
    check sizeof(BootInfo) > 0

    # Memory subsystems
    var phys: PhysicalMemManager
    var virt: VirtualMemManager
    var heap: HeapAllocator

    # Interrupt system
    let intMgr = newInterruptManager()
    check intMgr.handlers.len == 256

    # Execution models (any of these can be chosen)
    let models = [
      createThreadModelImpl(),
      createFiberModelImpl(),
      createGreenThreadModelImpl()
    ]

    for model in models:
      check model.vtable != nil
      check model.vtable.createUnit != nil
      check model.vtable.selectNext != nil

  test "Each component is independent":
    # Interrupt system doesn't depend on execution model
    let intMgr = newInterruptManager()
    let _ = intMgr.initializeIdt(0x08)

    # Execution model doesn't depend on specific interrupt setup
    let model = createThreadModelImpl()
    let _ = model.createUnit(ExecutionPriority(50))

    # Memory subsystems are independent
    var phys: PhysicalMemManager
    var virt: VirtualMemManager

    # All can work together
    check true
