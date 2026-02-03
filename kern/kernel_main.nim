# SPDX-License-Identifier: GPL-2.0
## Kernel Main - Orchestration & Boot - LAYER 5
##
## Central orchestration point for kernel initialization.
## Demonstrates configuration-based, trait-driven design.
## Same kernel boots with different strategies:
## - Different execution models (threads, fibers, green threads)
## - Different memory strategies (free-list, buddy, slab)
## - Different IPC mechanisms (syscalls, shared memory, message queues)
## - Different scheduling algorithms
##
## Philosophy: Leave doors open for innovation, don't lock in traditional approaches

import ../arch/common/boot_info
import ../boot/bootloader
import ../mm/physical_manager
import ../mm/virtual_manager
import ../mm/heap_allocator
import ../kern/interrupts
import ../sched/execution_model
import ../sched/task_manager
import ../sched/scheduler
import ../core/types
import strformat

# ═══════════════════════════════════════════════════════════════════════════
# Kernel Configuration - Choose strategies at boot
# ═══════════════════════════════════════════════════════════════════════════

type
  MemoryStrategy* = enum
    ## Different memory allocation approaches
    msFreeList       ## Free-list allocator (current)
    msBuddy          ## Buddy system (future)
    msSlab           ## Slab allocator (future)

  SchedulingStrategy* = enum
    ## Different execution model approaches
    ssThreads        ## Preemptive kernel threads (SMP-ready)
    ssFibers         ## Lightweight cooperative fibers
    ssGreenThreads   ## User-space green threads
    ssHybrid         ## Mix strategies (future)

  IpcStrategy* = enum
    ## Different IPC mechanisms
    ipSyscalls       ## Traditional syscall-based (current)
    ipSharedMemory   ## Fast shared memory (for unikernel)
    ipMessageQueue   ## Async message passing (for microkernel)
    ipCapability     ## Capability-based (Genode-style, future)

  SchedulingAlgorithm* = enum
    ## Different scheduling policies
    saRoundRobin     ## Simple round-robin (current)
    saPriority       ## Priority-based (future)
    saEdf            ## Earliest deadline first (real-time)
    saCfs            ## Completely fair scheduler (Linux-style)

type
  KernelConfig* = object
    ## Configurable kernel boot parameters
    ## Change these to boot with different strategies
    memoryStrategy*: MemoryStrategy
    schedulingStrategy*: SchedulingStrategy
    ipcStrategy*: IpcStrategy
    schedulingAlgorithm*: SchedulingAlgorithm
    cpuCount*: int
    heapSize*: uint64
    enablePreemption*: bool
    debugOutput*: bool

# ═══════════════════════════════════════════════════════════════════════════
# Global Kernel State
# ═══════════════════════════════════════════════════════════════════════════

var
  gBootInfo*: BootInfo
  gKernelConfig*: KernelConfig
  gPhysMemMgr*: PhysicalMemManager
  gVirtMemMgr*: VirtualMemManager
  gKernelHeap*: HeapAllocator
  gInterruptMgr*: InterruptManager
  gTaskMgr*: TaskManager
  gScheduler*: SchedulerManager

# ═══════════════════════════════════════════════════════════════════════════
# Early Console Output (Before Full Driver)
# ═══════════════════════════════════════════════════════════════════════════

proc earlyPrint*(msg: string) =
  ## Early console output via VGA text mode
  ## Used during boot before serial driver is ready
  ## Temporary - will be replaced by full console driver in TASK 1.5
  var ptr = cast[ptr uint16](0xB8000)
  for c in msg:
    if c == '\0': break
    ptr[] = uint16(c) or 0x0F00  # White on black
    inc(ptr)

proc earlyPrintln*(msg: string) =
  ## Early console line with newline
  earlyPrint(msg)
  earlyPrint("\n")

# ═══════════════════════════════════════════════════════════════════════════
# Configuration - Predefined Setups for Different OS Types
# ═══════════════════════════════════════════════════════════════════════════

proc defaultConfig*(): KernelConfig =
  ## Default boot configuration (reference monolithic kernel)
  ## Good for: General purpose, testing, development
  KernelConfig(
    memoryStrategy: msFreeList,
    schedulingStrategy: ssThreads,
    ipcStrategy: ipSyscalls,
    schedulingAlgorithm: saRoundRobin,
    cpuCount: 4,
    heapSize: 512 * 1024 * 1024,
    enablePreemption: true,
    debugOutput: true
  )

proc fiberConfig*(): KernelConfig =
  ## Configuration for fiber-based (lightweight) kernel
  ## Good for: High concurrency, embedded, single-core
  KernelConfig(
    memoryStrategy: msFreeList,
    schedulingStrategy: ssFibers,
    ipcStrategy: ipSharedMemory,
    schedulingAlgorithm: saRoundRobin,
    cpuCount: 1,
    heapSize: 128 * 1024 * 1024,  # Smaller heap
    enablePreemption: false,
    debugOutput: true
  )

proc microkernelConfig*(): KernelConfig =
  ## Configuration for microkernel architecture
  ## Good for: Modularity, fault isolation, distributed systems
  ## Note: Will use message queue IPC once implemented
  KernelConfig(
    memoryStrategy: msFreeList,
    schedulingStrategy: ssGreenThreads,
    ipcStrategy: ipSyscalls,  # TODO: switch to ipMessageQueue
    schedulingAlgorithm: saRoundRobin,
    cpuCount: 1,
    heapSize: 256 * 1024 * 1024,
    enablePreemption: false,
    debugOutput: true
  )

proc unikernelConfig*(): KernelConfig =
  ## Configuration for unikernel (single-image OS)
  ## Good for: Serverless, containers, minimal footprint
  KernelConfig(
    memoryStrategy: msFreeList,
    schedulingStrategy: ssFibers,
    ipcStrategy: ipSharedMemory,
    schedulingAlgorithm: saRoundRobin,
    cpuCount: 1,
    heapSize: 64 * 1024 * 1024,  # Tiny heap
    enablePreemption: false,
    debugOutput: false  # Minimal output
  )

proc realtimeConfig*(): KernelConfig =
  ## Configuration for real-time OS (RTOS)
  ## Good for: Embedded control, robotics, timing-sensitive
  ## Note: Will use priority scheduling once implemented
  KernelConfig(
    memoryStrategy: msFreeList,  # TODO: switch to msSlab (predictable)
    schedulingStrategy: ssThreads,
    ipcStrategy: ipSyscalls,
    schedulingAlgorithm: saEdf,  # TODO: implement EDF
    cpuCount: 1,
    heapSize: 256 * 1024 * 1024,
    enablePreemption: true,
    debugOutput: true
  )

# ═══════════════════════════════════════════════════════════════════════════
# Subsystem Initialization - Using Existing Components
# ═══════════════════════════════════════════════════════════════════════════

proc initPhysicalMemory*(config: KernelConfig): Result[void, KernelError] =
  ## Initialize physical memory manager
  ## Reuses: PhysicalMemManager (already built in mm/physical_manager.nim)
  earlyPrintln("Initializing physical memory...")

  gPhysMemMgr = newPhysicalMemManager()
  let result = gPhysMemMgr.init(gBootInfo.memoryMap)

  if result.isErr():
    earlyPrintln("ERROR: Physical memory initialization failed")
    return err(result.error)

  let stats = fmt"Physical memory: {gBootInfo.getTotalMemory() / (1024*1024)}MB"
  earlyPrintln(stats)
  ok()

proc initVirtualMemory*(config: KernelConfig): Result[void, KernelError] =
  ## Initialize virtual memory manager
  ## Reuses: VirtualMemManager (already built in mm/virtual_manager.nim)
  earlyPrintln("Initializing virtual memory...")

  gVirtMemMgr = newVirtualMemManager()
  let result = gVirtMemMgr.init()

  if result.isErr():
    earlyPrintln("ERROR: Virtual memory initialization failed")
    return err(result.error)

  earlyPrintln("Virtual memory initialized")
  ok()

proc initHeap*(config: KernelConfig): Result[void, KernelError] =
  ## Initialize kernel heap
  ## Reuses: HeapAllocator (already built in mm/heap_allocator.nim)
  earlyPrintln("Initializing kernel heap...")

  # TODO: Strategy-based heap selection
  # For now, only FreeList available
  # Future: switch between msFreeList, msBuddy, msSlab
  match config.memoryStrategy:
    of msFreeList:
      gKernelHeap = newHeapAllocator()
      # Heap is initialized with reserved memory from layout.nim (future TASK 1.7)
      earlyPrintln(fmt"Kernel heap: {config.heapSize / (1024*1024)}MB")
      ok()
    of msBuddy:
      earlyPrintln("ERROR: Buddy allocator not yet implemented")
      err(keNotImplemented)
    of msSlab:
      earlyPrintln("ERROR: Slab allocator not yet implemented")
      err(keNotImplemented)

proc initInterrupts*(config: KernelConfig): Result[void, KernelError] =
  ## Initialize interrupt system
  ## Reuses: InterruptManager (already built in kern/interrupts.nim)
  earlyPrintln("Initializing interrupt system...")

  gInterruptMgr = newInterruptManager()
  let initResult = gInterruptMgr.initializeIdt(0x08)  # Kernel code segment

  if initResult.isErr():
    earlyPrintln("ERROR: IDT initialization failed")
    return err(initResult.error)

  let handlerResult = gInterruptMgr.installDefaultHandlers()

  if handlerResult.isErr():
    earlyPrintln("ERROR: Exception handler installation failed")
    return err(handlerResult.error)

  earlyPrintln("Interrupt system initialized (256 vectors)")
  ok()

proc selectExecutionModel*(config: KernelConfig): ExecutionModel =
  ## Select execution model based on configuration
  ## Reuses: ThreadModel, FiberModel, GreenThreadModel (already built)
  ## Philosophy: Model chosen at boot time, not hardcoded
  earlyPrintln("Selecting execution model...")

  match config.schedulingStrategy:
    of ssThreads:
      earlyPrintln("  Using thread-based model (preemptive, SMP-ready)")
      return createThreadModelImpl()
    of ssFibers:
      earlyPrintln("  Using fiber-based model (cooperative, lightweight)")
      return createFiberModelImpl()
    of ssGreenThreads:
      earlyPrintln("  Using green thread model (user-space, balanced)")
      return createGreenThreadModelImpl()
    of ssHybrid:
      earlyPrintln("ERROR: Hybrid model not yet implemented")
      # TODO: Implement hybrid model
      return createThreadModelImpl()  # Fallback

proc initScheduling*(config: KernelConfig): Result[void, KernelError] =
  ## Initialize task manager and scheduler
  ## Reuses: TaskManager, SchedulerManager, ExecutionModels (already built)
  earlyPrintln("Initializing task management and scheduling...")

  gTaskMgr = newTaskManager(gKernelHeap, gVirtMemMgr)
  earlyPrintln(fmt"Task manager created (heap-based allocation)")

  let execModel = selectExecutionModel(config)
  gScheduler = newSchedulerManager(gTaskMgr, config.cpuCount, execModel)

  earlyPrintln(fmt"Scheduler created ({config.cpuCount} CPUs)")
  earlyPrintln(fmt"Preemption: {'enabled' if config.enablePreemption else 'disabled'}")

  # TODO: Create idle tasks (TASK 1.8)
  # TODO: Load init process (future)

  ok()

# ═══════════════════════════════════════════════════════════════════════════
# Boot Sequence - Call Subsystems in Order
# ═══════════════════════════════════════════════════════════════════════════

proc kernelMainWithConfig*(config: KernelConfig): void =
  ## Main kernel function with chosen configuration
  ## This demonstrates the orchestration pattern:
  ## - Reuse existing components
  ## - Wire them together via traits/interfaces
  ## - Same kernel works with different strategies

  gKernelConfig = config

  if config.debugOutput:
    earlyPrintln("")
    earlyPrintln("╔════════════════════════════════════════════════════════════╗")
    earlyPrintln("║            NimixOS Kernel Bootstrap                        ║")
    earlyPrintln("║     Innovation-First, Component-Based Architecture         ║")
    earlyPrintln("╚════════════════════════════════════════════════════════════╝")
    earlyPrintln("")

  # Step 1: Parse boot information (from bootloader.nim - already done by boot.asm)
  # Boot info was extracted in early_init.nim (TASK 1.3)
  earlyPrintln("Boot information parsed")

  # Step 2: Initialize physical memory
  let physResult = initPhysicalMemory(config)
  if physResult.isErr():
    earlyPrintln("FATAL: Cannot continue without physical memory")
    while true: discard  # Halt

  # Step 3: Initialize virtual memory
  let virtResult = initVirtualMemory(config)
  if virtResult.isErr():
    earlyPrintln("FATAL: Cannot continue without virtual memory")
    while true: discard  # Halt

  # Step 4: Initialize heap
  let heapResult = initHeap(config)
  if heapResult.isErr():
    earlyPrintln("FATAL: Cannot continue without heap")
    while true: discard  # Halt

  # Step 5: Initialize interrupts
  let intResult = initInterrupts(config)
  if intResult.isErr():
    earlyPrintln("FATAL: Cannot continue without interrupt system")
    while true: discard  # Halt

  # Step 6: Initialize scheduling
  let schedResult = initScheduling(config)
  if schedResult.isErr():
    earlyPrintln("FATAL: Cannot continue without scheduler")
    while true: discard  # Halt

  # Step 7: Console driver (TASK 1.5 - future)
  # TODO: Replace earlyPrintln with full console driver
  earlyPrintln("")
  earlyPrintln("All subsystems initialized successfully!")

  # Step 8: Create idle task and start scheduler (TASK 1.8, 1.10 - future)
  # TODO: Create idle task
  # TODO: Start scheduler
  earlyPrintln("")
  earlyPrintln("Ready to start scheduler...")
  earlyPrintln("(Idle task creation pending - TASK 1.8)")
  earlyPrintln("(Scheduler start pending - TASK 1.10)")

  if config.debugOutput:
    earlyPrintln("")
    earlyPrintln("Configuration:")
    earlyPrintln(fmt"  Memory Strategy: {config.memoryStrategy}")
    earlyPrintln(fmt"  Scheduling Strategy: {config.schedulingStrategy}")
    earlyPrintln(fmt"  IPC Strategy: {config.ipcStrategy}")
    earlyPrintln(fmt"  CPU Count: {config.cpuCount}")

  earlyPrintln("")
  earlyPrintln("Kernel bootstrap complete!")

proc kernelMain*() =
  ## Default kernel entry point
  ## Uses reference monolithic kernel configuration
  ## Can be called from boot.asm
  let config = defaultConfig()
  kernelMainWithConfig(config)

# ═══════════════════════════════════════════════════════════════════════════
# Entry Points for Different OS Variants - For Experimentation
# ═══════════════════════════════════════════════════════════════════════════

proc kernelMainFiber*() =
  ## Boot with fiber-based lightweight kernel
  ## Useful for: testing, embedded, single-core systems
  earlyPrintln("Booting fiber-based kernel variant...")
  let config = fiberConfig()
  kernelMainWithConfig(config)

proc kernelMainMicrokernel*() =
  ## Boot with microkernel-style configuration
  ## Useful for: modular systems, fault isolation
  earlyPrintln("Booting microkernel-style variant...")
  let config = microkernelConfig()
  kernelMainWithConfig(config)

proc kernelMainUnikernel*() =
  ## Boot with unikernel configuration
  ## Useful for: serverless, containers, minimal systems
  earlyPrintln("Booting unikernel variant...")
  let config = unikernelConfig()
  kernelMainWithConfig(config)

proc kernelMainRealtime*() =
  ## Boot with real-time OS configuration
  ## Useful for: embedded control, timing-critical systems
  earlyPrintln("Booting real-time OS variant...")
  let config = realtimeConfig()
  kernelMainWithConfig(config)

# ═══════════════════════════════════════════════════════════════════════════
# Notes on Design Philosophy
# ═══════════════════════════════════════════════════════════════════════════

## WHY THIS DESIGN?
##
## Traditional OS kernel has everything hardcoded:
##   - Only one memory allocator
##   - Only one scheduling algorithm
##   - Only one IPC mechanism
##   - Hard to experiment, modify, or test alternatives
##
## NimixOS approach uses configuration + traits:
##   - Choose strategy at boot (via KernelConfig)
##   - Implementations vary, interface stays same (via traits)
##   - Same kernel binary, different behaviors
##   - Easy to experiment with alternatives
##
## BENEFITS:
##
## 1. Research-friendly:
##    - Compare algorithms without code changes
##    - Run multiple variants on same hardware
##    - GPU can simulate all variants in parallel
##
## 2. Variant-friendly:
##    - Monolithic kernel (reference)
##    - Microkernel (different IPC)
##    - Unikernel (fibers + shared memory)
##    - Real-time RTOS (priority scheduling)
##    - All from same codebase
##
## 3. Maintainable:
##    - Clear separation of concerns
##    - Easy to understand component relationships
##    - Documented alternatives and future extensions
##
## NEXT STEPS:
##
## TASK 1.5: Console driver (replace earlyPrintln)
## TASK 1.8: Idle task creation
## TASK 1.10: Scheduler initialization
## Then: Boot on QEMU and verify output
