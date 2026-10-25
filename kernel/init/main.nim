# SPDX-License-Identifier: GPL-2.0
## Kernel Main - Entry Point and Boot Orchestration
##
## Exported entry points: kernelMain (from bootloader), runKernel (orchestrator).
## All init logic delegated to kernel/{core,services}/init.nim.

import ../../core/types
import ../../core/serial
import ../../core/debug
import ../../core/log
import ../../arch/common/boot_info
import ../../boot/bootloader
import ../../shell/shell
import ../../kernel/core/init
import ../../kernel/services/init
import ../../kernel/models/monolithic
import ../../kernel/models/microkernel
import ../../kernel/models/sasos
import boot_helpers
import ../config

when defined(amd64) or defined(x86_64):
  import ../../arch/x86_64/cpu_primitives

when defined(testMode):
  import ../../tests/kernel_tests/main as kernelTests
  import ../../kernel/process_table   # procSleepUntil, procTable
  import ../../drivers/pit            # pitTicks
  const userTestsElf = staticRead("../../build/apps/user_tests.elf")

# ═══════════════════════════════════════════════════════════════════════════
# Boot Orchestration (Step 1 → Core, Step 2 → Model, Step 3 → Services, Step 4 → Shell/Test)
# ═══════════════════════════════════════════════════════════════════════════

proc runKernel*(bootInfo: ptr BootInfo) =
  ## Orchestrate kernel boot: core → model → services → shell.
  assert bootInfo != nil
  klog(llInfo, "[MAIN] ════════════════════════════════════════════════")
  klog(llInfo, "[MAIN] Step 1: CORE KERNEL")
  klog(llInfo, "[MAIN] ════════════════════════════════════════════════")
  let core = initCoreKernel(bootInfo)
  assert core != nil

  klog(llInfo, "[MAIN] ════════════════════════════════════════════════")
  klog(llInfo, "[MAIN] Step 2: KERNEL MODEL")
  klog(llInfo, "[MAIN] ════════════════════════════════════════════════")
  klog(llInfo, "[MAIN] Selecting kernel model: " & KernelModel)
  when IsMonolithic:
    initMonolithicModel()
  elif IsSasos:
    initSasosModel()
  elif IsMicrokernel:
    initMicrokernelModel()
  else:
    initMonolithicModel()

  klog(llInfo, "[MAIN] ════════════════════════════════════════════════")
  klog(llInfo, "[MAIN] Step 3: SERVICES")
  klog(llInfo, "[MAIN] ════════════════════════════════════════════════")
  initServices()

  klog(llInfo, "[MAIN] ════════════════════════════════════════════════")
  klog(llInfo, "[MAIN] Step 4: ENTERING SHELL")
  klog(llInfo, "[MAIN] ════════════════════════════════════════════════")

  when defined(testMode):
    klog(llInfo, "[MAIN] testMode: kernel tests (ring 0)")
    cli()
    kernelTests.kernelTestMain()
    sti()

    klog(llInfo, "[MAIN] testMode: user tests (ring 3)")
    var userTestsBuf = userTestsElf
    cli()
    launchElfBytes("user_tests.elf", cast[ptr byte](addr userTestsBuf[0]), userTestsBuf.len)
    sti()
    procSleepUntil(int(procTable.current), pitTicks() + 500)
    klog(llInfo, "[MAIN] testMode: complete — halting")
    while true: hlt()

  runShell(core.physMgr)

# ═══════════════════════════════════════════════════════════════════════════
# Bootloader Entry Point
# ═══════════════════════════════════════════════════════════════════════════

proc kernelMain*(magicReg: uint32, infoPtr: pointer) {.exportc.} =
  ## Called from boot_asm.S after multiboot probe. Parse + orchestrate.
  earlyPutString("[BOOT] kernelMain entry\n")
  discard earlyDebug(magicReg, infoPtr)
  earlyPutString("[BOOT] earlyDebug complete\n")

  var bootInfo: BootInfo
  parseOrFallback(magicReg, infoPtr, bootInfo)
  earlyPutString("[BOOT] parseOrFallback complete\n")

  earlyPutString("[BOOT] Calling runKernel...\n")
  runKernel(addr bootInfo)

# ═══════════════════════════════════════════════════════════════════════════
# Standalone Test Entry (local testing without bootloader)
# ═══════════════════════════════════════════════════════════════════════════

when defined(kernelTestMode):
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
