# SPDX-License-Identifier: GPL-2.0
## Kernel Main - Entry Point and Initialization
##
## This is the main kernel initialization module.
## It wires up all managers following the dependency graph.

import ../../core/types
import ../../core/serial
import ../../core/debug
import ../../core/log
import ../../arch/common/boot_info
import ../../mm/physical_manager
import ../../mm/virtual_manager
import ../../mm/heap_manager

import ../../sched/task_manager
import ../../sched/scheduler
import ../../boot/bootloader
import ../../shell/shell
import ../../kernel/models/monolithic
import ../../kernel/driver_registry
import ../../drivers/pic
import ../../drivers/pit
import ../../drivers/ps2_keyboard
import ../../drivers/vga_text
import ../../kernel/event_server

# ═══════════════════════════════════════════════════════════════════════════
# Linker Script Symbols
# ═══════════════════════════════════════════════════════════════════════════

proc getKernelEnd*(): uint64 =
  ## Get the physical end address of the kernel image (from linker script).
  ## This is the address right after kernel BSS — all kernel code/data/BSS
  ## resides below this address.
  {.emit: """
    extern char kernel_end[];
    `result` = (unsigned long long)kernel_end;
  """.}

when defined(amd64) or defined(x86_64):
  import ../../arch/x86_64/cpu_primitives
  import ../../arch/x86_64/rtl_stubs

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
  klog(llInfo, "[INIT] Initializing memory management...")

  # ── Debug: dump memory map ──────────────────────────────────────
  kprintln("  Memory map dump:")
  for i in 0..<k.bootInfo.memoryMap.count:
    let r = k.bootInfo.memoryMap.regions[i]
    kprint("    [")
    kprintInt(i)
    kprint("] base=0x")
    defaultSerial.putHex(uint64(r.base))
    kprint(" length=0x")
    defaultSerial.putHex(r.length)
    kprint(" (")
    kprintInt(int64(r.length div (1024*1024)))
    kprint(" MiB) type=")
    kprintInt(int64(r.regionType.ord))
    kprintln("")

  # Calculate bitmap size based on USABLE memory only
  # (excluding reserved MMIO regions at very high addresses)
  let highestAddr = getHighestUsableAddress(k.bootInfo[])
  kprint("  Highest usable address: 0x")
  kprintHex(uint64(highestAddr))
  kprintln("")

  let totalFrames = (uint64(highestAddr) + FrameSize - 1) div FrameSize
  let bitmapSize = (totalFrames + 63) div 64 * 8  # bytes

  kprint("  Total usable memory: ")
  kprintInt(int64(uint64(highestAddr) div MiB))
  kprintln(" MiB")

  kprint("  Total frames: ")
  kprintInt(int64(totalFrames))
  kprintln("")

  kprint("  Bitmap size needed: ")
  kprintInt(int64(bitmapSize))
  kprintln(" bytes")

  # Get kernel end address from linker script, so we know where our
  # own code/data/BSS lives and can avoid placing the bitmap there.
  let kernelEndAddr = getKernelEnd()
  k.bootInfo.kernelPhysEnd = PhysAddr(kernelEndAddr)
  kprint("  Kernel end: 0x")
  kprintHex(kernelEndAddr)
  kprintln("")

  # Place the bitmap right after the kernel image (page-aligned).
  # The kernel BSS (including ARC heap) extends to kernel_end; memory
  # beyond that is available for bitmap and other allocations.
  let bitmapPhysAddr = alignUp(kernelEndAddr, FrameSize)
  let bitmapEndAddr = bitmapPhysAddr + bitmapSize
  kprint("  Bitmap at: 0x")
  kprintHex(bitmapPhysAddr)
  kprint(" - 0x")
  kprintHex(bitmapEndAddr)
  kprintln("")

  let bitmapAddr = cast[pointer](bitmapPhysAddr)

  # Initialize physical memory manager
  k.physMgr = PhysicalMemManager()
  k.physMgr.initFromBootInfo(k.bootInfo, bitmapAddr)

  kprint("  Free memory: ")
  kprintInt(int64(k.physMgr.freeMemory() div MiB))
  kprintln(" MiB")

  # Initialize virtual memory manager
  kprintln("  Creating VirtualMemManager...")
  k.virtMgr = newVirtualMemManager(k.physMgr)
  kprintln("  VirtualMemManager created")

  kprintln("  Initializing kernel address space...")
  let initResult = k.virtMgr.initKernelSpace()
  if initResult.isErr:
    kprintln("  ERROR: Could not initialize kernel address space")
    return false

  kprintln("  Virtual memory manager initialized")

  # Initialize heap manager
  kprintln("  Creating HeapManager...")
  k.heapMgr = newHeapManager(k.physMgr, k.virtMgr)
  kprintln("  HeapManager created")

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
  klog(llInfo, "[INIT] Initializing scheduler...")

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
# Kernel Entry Points
# ═══════════════════════════════════════════════════════════════════════════

proc runKernel(bootInfo: ptr BootInfo) =
  ## Initialize and run the kernel (internal, used by both boot paths)
  let k = initKernel(bootInfo)

  if not k.initialized:
    panic("Kernel initialization failed")

  kprintln("Starting scheduler...")

  # Scheduler loop — calls schedule() in a loop to dispatch tasks.
  # In a real kernel the idle task or timer interrupts drive this loop;
  # here we drive it from the boot CPU until context switching lands
  # on the idle task (which calls hlt in its own loop).
  eventServerInit()
  klog(llInfo, "Event server ready")
  picInit()
  klog(llInfo, "PIC 8259A remapped to vectors 0x20-0x2F")
  initMonolithicModel()
  klog(llInfo, "Kernel model ready")

  pitInit(100)
  pitRegisterHandler()
  picUnmask(0)
  klog(llInfo, "PIT timer: 100Hz, IRQ0 handler registered")

  # Register all drivers
  registerDriver(addr ps2KeyboardDriver)
  registerDriver(addr vgaTextDriver)

  # Probe: calls init() on each, returns counts
  let (drvOk, drvFail) = probeAllDrivers()
  klog(llInfo, "Drivers probed")
  klogInt(llInfo, "  ok:   ", int64(drvOk))
  klogInt(llInfo, "  fail: ", int64(drvFail))

  # Hand off to interactive shell — never returns.
  runShell(k.physMgr)

# earlyPutChar / earlyPutString / earlyPutHex are now in core/debug.nim

proc kernelMain*(magicReg: uint32, infoPtr: pointer) {.exportc.} =
  ## Kernel entry point called by the boot stub (assembly)
  ## - magicReg: Multiboot magic from EAX (0x2BADB002 for Multiboot1)
  ## - infoPtr:  Pointer to bootloader info structure from EBX

  # ═══════════════════════════════════════════════════════════════════
  # PHASE 1: EARLY DEBUG — inline asm, no dependencies
  # ═══════════════════════════════════════════════════════════════════
  earlyPutString("\n\n\n")
  earlyPutString("╔════════════════════════════════════════╗\n")
  earlyPutString("║        NimixOS Kernel — EARLY DEBUG   ║\n")
  earlyPutString("╚════════════════════════════════════════╝\n")
  earlyPutString("\n")

  # ── Magic number ──────────────────────────────────────────────────
  earlyPutString("[BOOT] magicReg = ")
  earlyPutHex(uint64(magicReg))
  earlyPutString("\n")
  earlyPutString("[BOOT] MULTIBOOT2_MAGIC = ")
  earlyPutHex(uint64(MULTIBOOT2_MAGIC))
  earlyPutString("\n")
  earlyPutString("[BOOT] MULTIBOOT1_MAGIC_BOOT = ")
  earlyPutHex(uint64(MULTIBOOT1_MAGIC_BOOT))
  earlyPutString("\n")

  # ── Detect protocol ───────────────────────────────────────────────
  let detectedProto = detectProtocol(magicReg, infoPtr)
  earlyPutString("[BOOT] Detected protocol: ")
  case detectedProto
  of bpMultiboot1: earlyPutString("Multiboot1\n")
  of bpMultiboot2: earlyPutString("Multiboot2\n")
  of bpLimine:     earlyPutString("Limine\n")
  of bpUnknown:    earlyPutString("UNKNOWN\n")

  # ── Info pointer ──────────────────────────────────────────────────
  earlyPutString("[BOOT] infoPtr = ")
  earlyPutHex(cast[uint64](infoPtr))
  earlyPutString("\n")
  earlyPutString("[BOOT] infoPtr & 0xFFF = ")
  earlyPutHex(uint64(cast[uint64](infoPtr) and 0xFFF))
  earlyPutString(" (should be 0 if page-aligned)\n")

  # ═══════════════════════════════════════════════════════════════════
  # PHASE 2: BOOTLOADER INFO HEADER (compact)
  # ═══════════════════════════════════════════════════════════════════
  # For verbose hex dumps, use earlyDumpMultiboot2Info() / earlyDumpHex()
  # from core/debug.nim

  if detectedProto == bpMultiboot2:
    let base = cast[uint64](infoPtr)
    let totalSize = cast[ptr uint32](base)[]
    earlyPutString("[INFO] Multiboot2: total_size=")
    earlyPutInt(int64(totalSize))
    earlyPutString(" end=0x")
    earlyPutHex(base + uint64(totalSize))
    earlyPutString("\n")

  # ═══════════════════════════════════════════════════════════════════
  # PHASE 3: PARSE BOOT INFO
  # ═══════════════════════════════════════════════════════════════════
  earlyPutString("\n[PARSE] Calling parseBootInfo...\n")

  var bootInfo: BootInfo

  let parseResult = parseBootInfo(magicReg, infoPtr, bootInfo)

  earlyPutString("[PARSE] parseBootInfo returned\n")
  if parseResult.isErr:
    earlyPutString("[PARSE] ERROR: ")
    let errStr = bootErrorToString(parseResult.error)
    earlyPutString(cstring(errStr))
    earlyPutString("\n")

    # Fall back to minimal defaults so we can still boot.
    for i in 0..<32:
      bootInfo.bootProtocol[i] = '\0'
    let proto = "Fallback"
    for i in 0..<proto.len:
      bootInfo.bootProtocol[i] = proto[i]
    bootInfo.cpuCount = 1
    bootInfo.memoryMap.count = 2
    bootInfo.memoryMap.regions[0] = MemoryRegion(
      base: PhysAddr(0), length: 640 * KiB, regionType: memAvailable
    )
    bootInfo.memoryMap.regions[1] = MemoryRegion(
      base: PhysAddr(1 * MiB), length: 127 * MiB, regionType: memAvailable
    )
  else:
    earlyPutString("[PARSE] SUCCESS\n")

  # ═══════════════════════════════════════════════════════════════════
  # PHASE 4: PROCEED TO FULL INIT
  # ═══════════════════════════════════════════════════════════════════
  earlyPutString("\n[BOOT] Calling runKernel...\n")
  runKernel(addr bootInfo)

# ── Standalone Test Entry Point ──────────────────────────────────
# NOT compiled during kernel build (no -d:kernelTestMode).
# Run via: nim c -d:kernelTestMode -r kernel/init/main.nim
when defined(kernelTestMode):
  # Create a minimal boot info for testing without bootloader
  var fakeBootInfo: BootInfo
  fakeBootInfo.cpuCount = 1
  fakeBootInfo.memoryMap.regions[0] = MemoryRegion(
    base: PhysAddr(0), length: 640 * KiB, regionType: memAvailable
  )
  fakeBootInfo.memoryMap.regions[1] = MemoryRegion(
    base: PhysAddr(1 * MiB), length: 127 * MiB, regionType: memAvailable
  )
  fakeBootInfo.memoryMap.count = 2
  let proto = "Test"
  for i in 0..<proto.len:
    fakeBootInfo.bootProtocol[i] = proto[i]
  runKernel(addr fakeBootInfo)
