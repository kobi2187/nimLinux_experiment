# SPDX-License-Identifier: GPL-2.0
## Kernel Core Initialization
##
## Pure hardware + memory + scheduler setup. No services, no servers.
## This is what MUST complete before anything else runs.

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

when defined(amd64) or defined(x86_64):
  import ../../arch/x86_64/cpu_primitives
  import ../../arch/x86_64/rtl_stubs

type
  CoreKernel* = ref object
    ## Minimal kernel state: memory + scheduling only
    bootInfo*: ptr BootInfo
    physMgr*: PhysicalMemManager
    virtMgr*: VirtualMemManager
    heapMgr*: HeapManager
    taskMgr*: TaskManager
    schedMgr*: SchedulerManager

var coreKernel*: CoreKernel

# ═══════════════════════════════════════════════════════════════════════════
# Phase 1: Serial + Bootinfo
# ═══════════════════════════════════════════════════════════════════════════

proc initSerialConsole*() =
  ## Initialize early serial output (must be first).
  initSerial()

proc logBootProtocol*(bootInfo: ptr BootInfo) =
  kprint("Boot protocol: ")
  var protoName: string = ""
  for c in bootInfo.bootProtocol:
    if c == '\0': break
    protoName.add(c)
  kprintln(protoName)

# ═══════════════════════════════════════════════════════════════════════════
# Phase 2: Memory Management
# ═══════════════════════════════════════════════════════════════════════════

proc getKernelEnd*(): uint64 =
  {.emit: """
    extern char kernel_end[];
    `result` = (unsigned long long)kernel_end;
  """.}

proc dumpMemoryMap(bootInfo: ptr BootInfo; highestAddr: uint64; bitmapPhysAddr, bitmapSize: uint64) =
  when not defined(release):
    kprintln("  Memory map dump:")
    for i in 0..<bootInfo.memoryMap.count:
      let r = bootInfo.memoryMap.regions[i]
      kprint("    ["); kprintInt(i); kprint("] base=0x"); defaultSerial.putHex(uint64(r.base))
      kprint(" length=0x"); defaultSerial.putHex(r.length)
      kprint(" ("); kprintInt(int64(r.length div (1024*1024))); kprint(" MiB) type=")
      kprintInt(int64(r.regionType.ord)); kprintln("")
    kprint("  Total usable: "); kprintInt(int64(highestAddr div MiB)); kprintln(" MiB")
    kprint("  Bitmap: 0x"); kprintHex(bitmapPhysAddr); kprint(" - 0x")
    kprintHex(bitmapPhysAddr + bitmapSize); kprintln("")

proc initPhysicalMemory*(bootInfo: ptr BootInfo): PhysicalMemManager =
  let highestAddr    = getHighestUsableAddress(bootInfo[])
  let totalFrames    = (uint64(highestAddr) + FrameSize - 1) div FrameSize
  let bitmapSize     = (totalFrames + 63) div 64 * 8
  let kernelEndAddr  = getKernelEnd()
  bootInfo.kernelPhysEnd = PhysAddr(kernelEndAddr)
  let bitmapPhysAddr = alignUp(kernelEndAddr, FrameSize)

  dumpMemoryMap(bootInfo, uint64(highestAddr), bitmapPhysAddr, bitmapSize)

  result = PhysicalMemManager()
  result.initFromBootInfo(bootInfo, cast[pointer](bitmapPhysAddr))

  when not defined(release):
    kprint("  Free memory: "); kprintInt(int64(result.freeMemory() div MiB)); kprintln(" MiB")

proc initVirtualAndHeap*(physMgr: PhysicalMemManager; bootInfo: ptr BootInfo): tuple[virt: VirtualMemManager, heap: HeapManager] =
  result.virt = newVirtualMemManager(physMgr)
  let res = result.virt.initKernelSpace()
  if res.isErr:
    kprintln("PANIC: Virtual memory initialization failed")
    while true: discard
  registerDeviceMapper(result.virt)
  result.heap = newHeapManager(physMgr, result.virt)

# ═══════════════════════════════════════════════════════════════════════════
# Phase 3: Scheduler
# ═══════════════════════════════════════════════════════════════════════════

proc idleLoop() {.noReturn.} =
  while true:
    when defined(amd64) or defined(x86_64):
      hlt()
    else:
      discard

proc initTaskScheduler*(heapMgr: HeapManager; virtMgr: VirtualMemManager; bootInfo: ptr BootInfo): tuple[taskMgr: TaskManager, schedMgr: SchedulerManager] =
  let cpuCount = max(1, bootInfo.cpuCount)
  result.taskMgr  = newTaskManager(heapMgr, virtMgr)
  result.schedMgr = newSchedulerManager(result.taskMgr, cpuCount)

  let idleTask = result.taskMgr.createTask("idle", idleLoop, nil, MinPriority)
  if idleTask.isErr:
    kprintln("PANIC: Could not create idle task")
    while true: discard
  result.schedMgr.idleTask = idleTask.value

# ═══════════════════════════════════════════════════════════════════════════
# Main Initialization Sequence (Core Only)
# ═══════════════════════════════════════════════════════════════════════════

proc initCoreKernel*(bootInfo: ptr BootInfo): CoreKernel =
  ## Initialize kernel core (memory + scheduler).
  ## No services, no servers, no drivers beyond basic setup.

  result = CoreKernel(bootInfo: bootInfo)
  coreKernel = result

  # ─────────────────────────────────────────────────────────────────────────
  # PHASE 1: Serial Console
  # ─────────────────────────────────────────────────────────────────────────
  initSerialConsole()

  when not defined(release):
    kprintln("")
    kprintln("╔════════════════════════════════════════╗")
    kprintln("║           NimixOS Core Kernel          ║")
    kprintln("╚════════════════════════════════════════╝")
    kprintln("")

  logBootProtocol(bootInfo)

  # ─────────────────────────────────────────────────────────────────────────
  # PHASE 2: Memory Management (Physical → Virtual → Heap)
  # ─────────────────────────────────────────────────────────────────────────
  klog(llInfo, "[CORE] Phase 2: Memory Management")

  result.physMgr = initPhysicalMemory(bootInfo)
  klog(llInfo, "  ✓ Physical memory initialized")

  let (virtMgr, heapMgr) = initVirtualAndHeap(result.physMgr, bootInfo)
  result.virtMgr = virtMgr
  result.heapMgr = heapMgr
  klog(llInfo, "  ✓ Virtual memory + heap initialized")

  # ─────────────────────────────────────────────────────────────────────────
  # PHASE 3: Scheduling (Processes + Scheduler)
  # ─────────────────────────────────────────────────────────────────────────
  klog(llInfo, "[CORE] Phase 3: Scheduling")

  let (taskMgr, schedMgr) = initTaskScheduler(result.heapMgr, result.virtMgr, bootInfo)
  result.taskMgr = taskMgr
  result.schedMgr = schedMgr
  klog(llInfo, "  ✓ Scheduler initialized")

  # ─────────────────────────────────────────────────────────────────────────
  # Core Ready
  # ─────────────────────────────────────────────────────────────────────────
  klog(llInfo, "[CORE] ✓ Kernel core ready")
