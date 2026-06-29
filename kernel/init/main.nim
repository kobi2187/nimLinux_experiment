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
import ../../mm/device_mmio
import ../../mm/heap_manager

import ../../sched/task_manager
import ../../sched/scheduler
import ../../boot/bootloader
import ../../shell/shell
import ../../kernel/models/monolithic
import ../../kernel/models/microkernel
import ../../kernel/models/sasos
import ../config
import ../../kernel/driver_registry
import ../../drivers/pic
import ../../drivers/pit
import ../../kern/interrupts
import ../../drivers/ps2_keyboard
import ../../drivers/ps2_mouse
import ../../drivers/vga_text
import ../../kernel/event_server
import ../../arch/x86_64/syscall_gate
import ../../servers/ping_server
import ../../ipc/server_chan
import ../../fs/vfs
import ../../fs/fatfs
import ../../fs/fatfs_write
import ../../fs/littlefs
import ../../fs/lwext4
import ../../mm/region_allocator
import ../../kernel/process_table
import ../../kernel/cap/capability
import ../../kernel/cap/cap_registry
import ../../drivers/pci/pci_device
import ../../drivers/virtio/virtio_net
import ../../drivers/virtio/virtio_blk
import ../../drivers/rtc

when defined(testMode):
  import ../../tests/kernel_tests/main as kernelTests
  const userTestsElf = staticRead("../../build/apps/user_tests.elf")

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

proc dumpMemoryMap(k: Kernel; highestAddr: uint64; bitmapPhysAddr, bitmapSize: uint64) =
  when not defined(release):
    kprintln("  Memory map dump:")
    for i in 0..<k.bootInfo.memoryMap.count:
      let r = k.bootInfo.memoryMap.regions[i]
      kprint("    ["); kprintInt(i); kprint("] base=0x"); defaultSerial.putHex(uint64(r.base))
      kprint(" length=0x"); defaultSerial.putHex(r.length)
      kprint(" ("); kprintInt(int64(r.length div (1024*1024))); kprint(" MiB) type=")
      kprintInt(int64(r.regionType.ord)); kprintln("")
    kprint("  Total usable: "); kprintInt(int64(highestAddr div MiB)); kprintln(" MiB")
    kprint("  Bitmap: 0x"); kprintHex(bitmapPhysAddr); kprint(" - 0x")
    kprintHex(bitmapPhysAddr + bitmapSize); kprintln("")

proc initPhysMgr(k: Kernel; bitmapAddr: pointer) =
  k.physMgr = PhysicalMemManager()
  k.physMgr.initFromBootInfo(k.bootInfo, bitmapAddr)
  when not defined(release):
    kprint("  Free memory: "); kprintInt(int64(k.physMgr.freeMemory() div MiB)); kprintln(" MiB")

proc initVirtHeap(k: Kernel): bool =
  k.virtMgr = newVirtualMemManager(k.physMgr)
  let res = k.virtMgr.initKernelSpace()
  if res.isErr:
    kprintln("  ERROR: Could not initialize kernel address space"); return false
  registerDeviceMapper(k.virtMgr)   # device drivers can now uncached-map BARs
  k.heapMgr = newHeapManager(k.physMgr, k.virtMgr)
  true

proc initMemory(k: Kernel): bool =
  klog(llInfo, "[INIT] Initializing memory management...")
  let highestAddr    = getHighestUsableAddress(k.bootInfo[])
  let totalFrames    = (uint64(highestAddr) + FrameSize - 1) div FrameSize
  let bitmapSize     = (totalFrames + 63) div 64 * 8
  let kernelEndAddr  = getKernelEnd()
  k.bootInfo.kernelPhysEnd = PhysAddr(kernelEndAddr)
  let bitmapPhysAddr = alignUp(kernelEndAddr, FrameSize)
  dumpMemoryMap(k, uint64(highestAddr), bitmapPhysAddr, bitmapSize)
  initPhysMgr(k, cast[pointer](bitmapPhysAddr))
  if not initVirtHeap(k): return false
  klog(llInfo, "[INIT] Memory management initialized")
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

  let cpuCount = max(1, k.bootInfo.cpuCount)
  k.taskMgr  = newTaskManager(k.heapMgr, k.virtMgr)
  k.schedMgr = newSchedulerManager(k.taskMgr, cpuCount)

  let idleTask = k.taskMgr.createTask("idle", idleLoop, nil, MinPriority)
  if idleTask.isErr:
    kprintln("  ERROR: Could not create idle task")
    return false

  k.schedMgr.idleTask = idleTask.value
  klog(llInfo, "[INIT] Scheduler initialized")
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

  when not defined(release):
    kprintln("")
    kprintln("╔════════════════════════════════════════╗")
    kprintln("║           NimixOS Kernel               ║")
    kprintln("╚════════════════════════════════════════╝")
    kprintln("")
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
  result.initialized = true

# ═══════════════════════════════════════════════════════════════════════════
# Kernel Entry Points
# ═══════════════════════════════════════════════════════════════════════════



proc initKernelModel() =
  klog(llInfo, "Selected kernel model: " & KernelModel)
  when IsMonolithic:
    initMonolithicModel(); klog(llInfo, "Monolithic kernel model initialized")
  elif IsSasos:
    initSasosModel();      klog(llInfo, "SASOS kernel model initialized")
  elif IsMicrokernel:
    initMicrokernelModel(); klog(llInfo, "Microkernel model initialized")
  else:
    initMonolithicModel(); klog(llInfo, "Unknown model — defaulting to monolithic")
  klog(llInfo, "Kernel model ready")

proc initTimerAndInput() =
  discard initInterruptSystem(0x08'u16)
  klog(llInfo, "Interrupt system initialized")
  pitInit(100); pitRegisterHandler(); picUnmask(0)
  klog(llInfo, "PIT timer: 100Hz, IRQ0 handler registered")
  kbdRegisterHandler(); picUnmask(1)
  klog(llInfo, "PS2 keyboard: IRQ1 handler registered")
  mouseRegisterHandler(); picUnmask(2); picUnmask(12)
  klog(llInfo, "PS2 mouse: IRQ12 handler registered")

proc wireVirtioNet() =
  if not virtioNetInit():
    klog(llWarn, "virtio-net: not available"); return
  klog(llInfo, "virtio-net: initialized")
  let netIrq = gVirtioNet.irqLine
  picUnmask(netIrq)
  discard getInterruptManager().registerExceptionHandler(
    uint32(irqToVector(int(netIrq))),
    proc(ctx: ptr ExceptionContext) {.nimcall.} =
      virtioNetIrqHandler(); picEoi(gVirtioNet.irqLine))
  klogInt(llInfo, "virtio-net: IRQ wired, line=", int64(netIrq))

proc initVirtioDevices() =
  pciScan()
  klogInt(llInfo, "PCI scan: devices found: ", int64(gPciCount))
  wireVirtioNet()
  if virtioBlkInit(): klog(llInfo, "virtio-blk: initialized")
  else:               klog(llWarn, "virtio-blk: not available")

proc enableInterrupts() =
  let intMgr = getInterruptManager()
  if intMgr != nil: intMgr.loadIdt(); klog(llInfo, "IDT loaded")
  sti(); klog(llInfo, "Interrupts enabled")

proc initDriverRegistry() =
  registerDriver(addr ps2KeyboardDriver)
  registerDriver(addr ps2MouseDriver)
  registerDriver(addr vgaTextDriver)
  let (drvOk, drvFail) = probeAllDrivers()
  klog(llInfo, "Drivers probed")
  klogInt(llInfo, "  ok:   ", int64(drvOk))
  klogInt(llInfo, "  fail: ", int64(drvFail))

proc spawnDispatcher() =
  var dispatchChan = serverChanCreate("dispatch")
  serverChanRegister(dispatchChan)
  klog(llInfo, "Dispatch channel registered")
  let slot = procSpawn("dispatcher", nil, tcRealtime, 250)
  if slot < 0: return
  procTable.tasks[slot].ipcCap = capGrant(procTable.tasks[slot].pid, capAdmin)
  discard capGrant(procTable.tasks[slot].pid, capFs)
  discard capGrant(procTable.tasks[slot].pid, capNet)
  discard capRegister("dispatch.admin", capAdmin)
  discard capRegister("dispatch.fs",    capFs)
  discard capRegister("dispatch.net",   capNet)
  klog(llInfo, "Dispatcher registered with capAdmin + capFs + capNet")

proc spawnInitialTasks() =
  discard procSpawn("idle",        idleTaskProc, tcApp,      0)
  discard procSpawn("shell",       nil,          tcServer,   128)
  discard procSpawn("ping_server", nil,          tcServer,   100)
  discard procSpawn("event_srv",   nil,          tcRealtime, 200)

var serverLoadBuf: array[512 * 1024, byte]   # 512 KB static buffer for server ELFs

proc mountDisk(): bool =
  ## Mount disk; log result. Returns true on success.
  registerFatFs()
  registerLittleFS()
  registerLwExt4()
  if vfsMount():
    klog(llInfo, "boot: VFS prefix-routed volumes mounted")
    return true
  klog(llWarn, "boot: disk not available — servers will not load")
  false

proc tryLoadServer(name: cstring): bool =
  ## Read a server ELF from disk into serverLoadBuf and spawn it ring-3.
  ## Returns true if the server was spawned successfully.
  var pathBuf: array[64, char]
  var path: cstring = name
  if name[0] != '/':
    # Prepend "/fat/" to default to the FAT volume
    var i = 0
    let prefix = "/fat/"
    while i < prefix.len:
      pathBuf[i] = prefix[i]
      inc i
    var j = 0
    while name[j] != '\0' and i < pathBuf.len - 1:
      pathBuf[i] = name[j]
      inc i; inc j
    pathBuf[i] = '\0'
    path = cast[cstring](addr pathBuf[0])

  let nbytes = vfsReadInto(path, cast[ptr byte](addr serverLoadBuf[0]),
                                  serverLoadBuf.len)
  if nbytes <= 0:
    klog(llWarn, "boot: server ELF not found on disk")
    return false
  launchElfBytes(name, cast[ptr byte](addr serverLoadBuf[0]), nbytes)
  klog(llInfo, "boot: server spawned")
  true

proc initServers() =
  assert true, "initServers: start"
  regionAllocInit()
  assert true, "initServers: after regionAllocInit"

  serverChanRegistryInit()
  assert true, "initServers: after serverChanRegistryInit"

  pingServerInit()
  assert true, "initServers: after pingServerInit"

  spawnInitialTasks()
  assert true, "initServers: after spawnInitialTasks"

  spawnDispatcher()
  assert true, "initServers: after spawnDispatcher"

  # DISABLED: VFS mount triggers a kernel fault loop (metadata_db seq[string] bug)
  # TODO: refactor metadata_db off seq[string] onto fixed-size arrays
  assert true, "initServers: skipping VFS mount (disabled for debugging)"
  # if mountDisk():
  #   discard tryLoadServer("fs_server.elf")

when defined(testMode):
  proc runTestMode() =
    klog(llInfo, "testMode: running kernel tests (ring 0)")
    cli()
    kernelTests.kernelTestMain()
    sti()
    klog(llInfo, "testMode: kernel tests done — launching user tests (ring 3)")
    var userTestsBuf = userTestsElf
    # ELF load + ring-3 spawn is not interrupt-safe: a PIT/IRQ firing mid-load
    # hangs the system non-deterministically (see TW#65). Mask while loading.
    cli()
    launchElfBytes("user_tests.elf", cast[ptr byte](addr userTestsBuf[0]), userTestsBuf.len)
    sti()
    procSleepUntil(int(procTable.current), pitTicks() + 500)
    klog(llInfo, "testMode: complete — halting")
    while true: hlt()

proc runKernel(bootInfo: ptr BootInfo) =
  assert bootInfo != nil, "runKernel: bootInfo is nil"
  let k = initKernel(bootInfo)
  assert k.initialized, "runKernel: Kernel initialization failed"
  kprintln("Starting scheduler...")

  assert true, "CP1: after kprintln"
  eventServerInit()
  assert true, "CP2: after eventServerInit"
  klog(llInfo, "Event server ready")

  assert true, "CP3: before picInit"
  picInit()
  assert true, "CP4: after picInit"
  klog(llInfo, "PIC 8259A remapped to vectors 0x20-0x2F")

  assert true, "CP5: before initKernelModel"
  initKernelModel()
  assert true, "CP6: after initKernelModel"

  assert true, "CP7: before initTimerAndInput"
  initTimerAndInput()
  assert true, "CP8: after initTimerAndInput"

  assert true, "CP9: before initVirtioDevices"
  initVirtioDevices()
  assert true, "CP10: after initVirtioDevices"

  assert true, "CP11: before enableInterrupts"
  enableInterrupts()
  assert true, "CP12: after enableInterrupts"

  assert true, "CP13: before initDriverRegistry"
  initDriverRegistry()
  assert true, "CP14: after initDriverRegistry"

  assert true, "CP15: before rtcReadDateTime"
  discard rtcReadDateTime()
  assert true, "CP16: after rtcReadDateTime"
  klog(llInfo, "RTC: wall clock read")

  assert true, "CP17: before syscallGateInit"
  syscallGateInit()
  assert true, "CP18: after syscallGateInit"
  klog(llInfo, "Syscall gate ready (ring 0<->3)")

  assert true, "CP19: before initServers"
  initServers()
  assert true, "CP20: after initServers"

  when defined(testMode):
    assert true, "CP21: before runTestMode"
    runTestMode()
    assert true, "CP22: after runTestMode"

  assert true, "CP23: before runShell"
  runShell(k.physMgr)
  assert true, "CP24: after runShell"

# earlyPutChar / earlyPutString / earlyPutHex are now in core/debug.nim

proc earlyLogMagic(magicReg: uint32) =
  earlyPutString("[BOOT] magicReg = ");          earlyPutHex(uint64(magicReg));            earlyPutString("\n")
  earlyPutString("[BOOT] MULTIBOOT2_MAGIC = ");  earlyPutHex(uint64(MULTIBOOT2_MAGIC));    earlyPutString("\n")
  earlyPutString("[BOOT] MULTIBOOT1_MAGIC = ");  earlyPutHex(uint64(MULTIBOOT1_MAGIC_BOOT)); earlyPutString("\n")

proc earlyLogProtocol(proto: BootloaderProtocol) =
  earlyPutString("[BOOT] Detected protocol: ")
  case proto
  of bpMultiboot1: earlyPutString("Multiboot1\n")
  of bpMultiboot2: earlyPutString("Multiboot2\n")
  of bpLimine:     earlyPutString("Limine\n")
  of bpUnknown:    earlyPutString("UNKNOWN\n")

proc earlyLogInfoPtr(infoPtr: pointer) =
  earlyPutString("[BOOT] infoPtr = ");       earlyPutHex(cast[uint64](infoPtr)); earlyPutString("\n")
  earlyPutString("[BOOT] infoPtr & 0xFFF = ")
  earlyPutHex(uint64(cast[uint64](infoPtr) and 0xFFF))
  earlyPutString(" (should be 0 if page-aligned)\n")

proc earlyLogMb2Header(infoPtr: pointer; proto: BootloaderProtocol) =
  if proto != bpMultiboot2: return
  let base = cast[uint64](infoPtr)
  let totalSize = cast[ptr uint32](base)[]
  earlyPutString("[INFO] Multiboot2: total_size="); earlyPutInt(int64(totalSize))
  earlyPutString(" end=0x"); earlyPutHex(base + uint64(totalSize)); earlyPutString("\n")

proc earlyDebug(magicReg: uint32; infoPtr: pointer): BootloaderProtocol =
  earlyPutString("\n\n\n╔════════════════════════════════════════╗\n")
  earlyPutString("║        NimixOS Kernel — EARLY DEBUG   ║\n")
  earlyPutString("╚════════════════════════════════════════╝\n\n")
  earlyLogMagic(magicReg)
  let proto = detectProtocol(magicReg, infoPtr)
  earlyLogProtocol(proto)
  earlyLogInfoPtr(infoPtr)
  earlyLogMb2Header(infoPtr, proto)
  proto

proc fallbackBootInfo(bi: var BootInfo) =
  for i in 0..<32: bi.bootProtocol[i] = '\0'
  let proto = "Fallback"
  for i in 0..<proto.len: bi.bootProtocol[i] = proto[i]
  bi.cpuCount = 1
  bi.memoryMap.count = 2
  bi.memoryMap.regions[0] = MemoryRegion(base: PhysAddr(0), length: 640 * KiB, regionType: memAvailable)
  bi.memoryMap.regions[1] = MemoryRegion(base: PhysAddr(1 * MiB), length: 127 * MiB, regionType: memAvailable)

proc parseOrFallback(magicReg: uint32; infoPtr: pointer; bi: var BootInfo) =
  earlyPutString("\n[PARSE] Calling parseBootInfo...\n")
  let res = parseBootInfo(magicReg, infoPtr, bi)
  earlyPutString("[PARSE] parseBootInfo returned\n")
  if res.isErr:
    earlyPutString("[PARSE] ERROR: ")
    earlyPutString(cstring(bootErrorToString(res.error)))
    earlyPutString("\n")
    fallbackBootInfo(bi)
  else:
    earlyPutString("[PARSE] SUCCESS\n")

proc kernelMain*(magicReg: uint32, infoPtr: pointer) {.exportc.} =
  discard earlyDebug(magicReg, infoPtr)
  var bootInfo: BootInfo
  parseOrFallback(magicReg, infoPtr, bootInfo)
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
