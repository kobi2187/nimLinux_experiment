# SPDX-License-Identifier: GPL-2.0
## Kernel Main - Entry Point and Initialization
##
## This is the main kernel initialization module.
## It wires up all managers following the dependency graph.

import ../../core/types
import ../../core/serial
import ../../arch/common/boot_info
import ../../mm/physical_manager
import ../../mm/virtual_manager
import ../../mm/heap_manager
import ../../sync/spinlock
import ../../sched/task_manager
import ../../sched/scheduler

when defined(amd64) or defined(x86_64):
  import ../../arch/x86_64/cpu_primitives

type
  # ═══════════════════════════════════════════════════════════════════════════
  # Kernel State
  # ═══════════════════════════════════════════════════════════════════════════

  Kernel* = ref object
    ## Complete kernel state with all managers
    initialized*: bool

    # Boot information
    bootInfo*: ptr BootInfo

    # Layer 2: Memory Management
    physMgr*: PhysicalMemManager
    virtMgr*: VirtualMemManager
    heapMgr*: HeapManager

    # Layer 4: Scheduling
    taskMgr*: TaskManager
    schedMgr*: SchedulerManager

var
  # Global kernel instance
  kernel*: Kernel

# ═══════════════════════════════════════════════════════════════════════════
# Panic Handler
# ═══════════════════════════════════════════════════════════════════════════

proc panic*(msg: string) {.noReturn.} =
  ## Kernel panic - unrecoverable error
  kprintln("")
  kprintln("======================================")
  kprintln("KERNEL PANIC - NOT SYNCING")
  kprintln("======================================")
  kprintln(msg)
  kprintln("======================================")
  kprintln("")
  kprintln("System halted.")

  when defined(amd64) or defined(x86_64):
    cli()
    while true:
      hlt()
  else:
    while true:
      discard

# ═══════════════════════════════════════════════════════════════════════════
# Memory Initialization
# ═══════════════════════════════════════════════════════════════════════════

proc initMemory(k: Kernel): bool =
  ## Initialize memory management subsystem
  kprintln("[INIT] Initializing memory management...")

  # Calculate bitmap size needed
  let highestAddr = getHighestAddress(k.bootInfo[])
  let totalFrames = (uint64(highestAddr) + FrameSize - 1) div FrameSize
  let bitmapSize = (totalFrames + 63) div 64 * 8  # bytes

  kprint("  Total memory: ")
  kprintInt(int64(uint64(highestAddr) div MiB))
  kprintln(" MiB")

  kprint("  Total frames: ")
  kprintInt(int64(totalFrames))
  kprintln("")

  # For early init, we need to find a free region for the bitmap
  # This is a simplified approach - a real kernel would be more careful
  var bitmapAddr: pointer = nil

  for i in 0..<k.bootInfo.memoryMap.count:
    let region = k.bootInfo.memoryMap.regions[i]
    if region.regionType == memAvailable and region.length >= bitmapSize + FrameSize:
      # Use start of this region for bitmap (page-aligned)
      let aligned = alignUp(uint64(region.base), FrameSize)
      bitmapAddr = cast[pointer](aligned)
      break

  if bitmapAddr == nil:
    kprintln("  ERROR: Could not find memory for bitmap")
    return false

  kprint("  Bitmap at: 0x")
  kprintHex(cast[uint64](bitmapAddr))
  kprintln("")

  # Initialize physical memory manager
  k.physMgr = PhysicalMemManager()
  k.physMgr.initFromBootInfo(k.bootInfo, bitmapAddr)

  kprint("  Free memory: ")
  kprintInt(int64(k.physMgr.freeMemory() div MiB))
  kprintln(" MiB")

  # Initialize virtual memory manager
  k.virtMgr = newVirtualMemManager(k.physMgr)

  let initResult = k.virtMgr.initKernelSpace()
  if initResult.isErr:
    kprintln("  ERROR: Could not initialize kernel address space")
    return false

  kprintln("  Virtual memory manager initialized")

  # Initialize heap manager
  k.heapMgr = newHeapManager(k.physMgr, k.virtMgr)

  kprintln("  Heap manager initialized")
  kprintln("[INIT] Memory management initialized")

  true

# ═══════════════════════════════════════════════════════════════════════════
# Scheduler Initialization
# ═══════════════════════════════════════════════════════════════════════════

proc idleLoop() {.noReturn.} =
  ## Idle task - runs when nothing else to do
  while true:
    when defined(amd64) or defined(x86_64):
      hlt()
    else:
      discard

proc initScheduler(k: Kernel): bool =
  ## Initialize scheduler subsystem
  kprintln("[INIT] Initializing scheduler...")

  # Get CPU count from boot info
  let cpuCount = max(1, k.bootInfo.cpuCount)
  kprint("  CPU count: ")
  kprintInt(cpuCount)
  kprintln("")

  # Initialize task manager
  k.taskMgr = newTaskManager(k.heapMgr, k.virtMgr)
  kprintln("  Task manager initialized")

  # Initialize scheduler
  k.schedMgr = newSchedulerManager(k.taskMgr, cpuCount)
  kprintln("  Scheduler manager initialized")

  # Create idle task
  let idleTask = k.taskMgr.createTask("idle", idleLoop, nil, MinPriority)
  if idleTask.isErr:
    kprintln("  ERROR: Could not create idle task")
    return false

  k.schedMgr.idleTask = idleTask.value
  kprintln("  Idle task created")

  kprintln("[INIT] Scheduler initialized")
  true

# ═══════════════════════════════════════════════════════════════════════════
# Kernel Initialization
# ═══════════════════════════════════════════════════════════════════════════

proc initKernel*(bootInfo: ptr BootInfo): Kernel =
  ## Initialize the kernel - main entry point
  ## This wires up all managers following the dependency graph

  result = Kernel(
    initialized: false,
    bootInfo: bootInfo
  )

  # Store global reference
  kernel = result

  # ═══════════════════════════════════════════════════════════════════════
  # EARLY INIT: Serial console for debugging
  # ═══════════════════════════════════════════════════════════════════════
  initSerial()

  kprintln("")
  kprintln("╔════════════════════════════════════════╗")
  kprintln("║           NimixOS Kernel               ║")
  kprintln("║     Dependency Graph Architecture      ║")
  kprintln("╚════════════════════════════════════════╝")
  kprintln("")

  # Print boot info
  kprint("Boot protocol: ")
  var protoName: string = ""
  for c in bootInfo.bootProtocol:
    if c == '\0': break
    protoName.add(c)
  kprintln(protoName)

  # ═══════════════════════════════════════════════════════════════════════
  # LAYER 2: Memory Management
  # ═══════════════════════════════════════════════════════════════════════
  if not result.initMemory():
    panic("Memory initialization failed")

  # ═══════════════════════════════════════════════════════════════════════
  # LAYER 4: Scheduling
  # ═══════════════════════════════════════════════════════════════════════
  if not result.initScheduler():
    panic("Scheduler initialization failed")

  # ═══════════════════════════════════════════════════════════════════════
  # Initialization Complete
  # ═══════════════════════════════════════════════════════════════════════
  kprintln("")
  kprintln("[INIT] Kernel initialization complete")
  kprintln("")

  result.initialized = true

# ═══════════════════════════════════════════════════════════════════════════
# Kernel Entry Point
# ═══════════════════════════════════════════════════════════════════════════

proc kernelMain*(bootInfo: ptr BootInfo) {.exportc.} =
  ## Kernel entry point called by bootloader
  let k = initKernel(bootInfo)

  if not k.initialized:
    panic("Kernel initialization failed")

  kprintln("Starting scheduler...")

  # Start the scheduler (this never returns)
  k.schedMgr.schedule()

  # Should never reach here
  panic("Scheduler returned unexpectedly")

# For testing without bootloader
when isMainModule:
  # Create a fake boot info for testing
  var fakeBootInfo: BootInfo
  fakeBootInfo.cpuCount = 1

  # Add some fake memory regions
  fakeBootInfo.memoryMap.regions[0] = MemoryRegion(
    base: PhysAddr(0),
    length: 640 * KiB,
    regionType: memAvailable
  )
  fakeBootInfo.memoryMap.regions[1] = MemoryRegion(
    base: PhysAddr(1 * MiB),
    length: 127 * MiB,
    regionType: memAvailable
  )
  fakeBootInfo.memoryMap.count = 2

  # Set boot protocol name
  let proto = "Test"
  for i in 0..<proto.len:
    fakeBootInfo.bootProtocol[i] = proto[i]

  kernelMain(addr fakeBootInfo)
