# SPDX-License-Identifier: GPL-2.0
## Kernel Services Initialization
##
## Loads after core kernel is ready. Brings up servers, IPC infrastructure,
## and optional services (filesystems, dispatchers, etc.).

import ../../core/types
import ../../core/log
import ../../kernel/core/init
import ../../kernel/config
import ../../kernel/process_table
import ../../kernel/driver_registry
import ../../kernel/module_loader
import ../../kernel/event_server
import ../../mm/region_allocator
import ../../ipc/server_chan
import ../../kernel/cap/capability
import ../../kernel/cap/cap_registry
import ../../servers/ping_server
import ../../drivers/virtio/virtio_net
import ../../drivers/virtio/virtio_blk
import ../../drivers/virtio/virtio_gpu
import ../../drivers/virtio/virtio_snd
import ../../drivers/virtio/virtio_input
import ../../drivers/pic
import ../../drivers/pit
import ../../drivers/tsc
import ../../mm/memory_windows
import ../../drivers/ps2_keyboard
import ../../drivers/ps2_mouse
import ../../drivers/vga_text
import ../../drivers/pci/pci_device
import ../../drivers/rtc
import ../../kern/interrupts
import ../../arch/x86_64/syscall_gate
import ../../kernel/abi/nimix_abi_impl   # user-fault policy
import ../../kernel/abi/task_cleanup
import ../../kernel/abi/user_args_gate
import ../buffers/kbuffers
import ../../fs/fatfs
import ../../fs/fatfs_write   # registerFatFs
import ../../fs/ramfs         # registerRamFs
import ../../shell/shell
import ../console/fb_console

when defined(amd64) or defined(x86_64):
  import ../../arch/x86_64/cpu_primitives

when IsMonolithic:
  import ../../fs/fatfs_module
  import ../../fs/lwext4
else:
  discard

# ═══════════════════════════════════════════════════════════════════════════
# Stage 1: Hardware (PIC, PIT, Input, Interrupts)
# ═══════════════════════════════════════════════════════════════════════════

proc initInterrupts*() =
  ## Setup IDT + exception handlers.
  discard initInterruptSystem(0x08'u16)
  klog(llInfo, "[SERVICES] ✓ Interrupt system ready")

proc initPIC*() =
  ## Remap PIC to vectors 0x20-0x2F.
  picInit()
  klog(llInfo, "[SERVICES] ✓ PIC remapped to 0x20-0x2F")

proc initTimers*() =
  ## Setup PIT for 100 Hz tick.
  pitInit(100)
  tscInit()          # fine clock: PIT channel 2 is free of the tick, and IRQs are still off
  if tscReady():
    if publishTimePage(tscClock()): klog(llInfo, "[TSC] ✓ time page published (apps read the clock without a syscall)")
    else: klog(llWarn, "[TSC] no time page window; apps use the coarse clock")
  pitRegisterHandler()
  picUnmask(0)
  klog(llInfo, "[SERVICES] ✓ PIT: 100 Hz, IRQ0 wired")

proc initInputDevices*() =
  ## Setup PS/2 keyboard + mouse.
  kbdRegisterHandler()
  picUnmask(1)
  klog(llInfo, "[SERVICES] ✓ PS2 keyboard: IRQ1 wired")

  mouseRegisterHandler()
  picUnmask(2)
  picUnmask(12)
  klog(llInfo, "[SERVICES] ✓ PS2 mouse: IRQ12 wired")

proc enableInterrupts*() =
  ## Load IDT and enable global interrupt flag.
  let intMgr = getInterruptManager()
  if intMgr != nil: intMgr.loadIdt()
  sti()
  klog(llInfo, "[SERVICES] ✓ Interrupts enabled")

# ═══════════════════════════════════════════════════════════════════════════
# Stage 2: Event Server + RTC
# ═══════════════════════════════════════════════════════════════════════════

proc initEventSystem*() =
  ## Setup kernel event pub/sub.
  eventServerInit()
  klog(llInfo, "[SERVICES] ✓ Event server ready")

proc initClock*() =
  ## Read RTC time.
  discard rtcReadDateTime()
  klog(llInfo, "[SERVICES] ✓ RTC clock initialized")

# ═══════════════════════════════════════════════════════════════════════════
# Stage 3: Drivers + I/O
# ═══════════════════════════════════════════════════════════════════════════

# PCI INTx lines are shared between devices: one dispatcher per line runs
# every handler on it, then EOIs. (Registering per device would let the last
# device silently replace the others' handler.)
const MaxIrqShares = 4
var gIrqHandlers: array[16, array[MaxIrqShares, proc() {.nimcall.}]]

proc irqLineDispatch(line: int) =
  for h in gIrqHandlers[line]:
    if h != nil: h()
  picEoi(uint8(line))

template lineEntry(n: static int): untyped =
  proc(ctx: ptr ExceptionContext) {.nimcall.} = irqLineDispatch(n)

proc wirePciIrq(line: uint8; handler: proc() {.nimcall.}) =
  ## Add `handler` to the device IRQ `line` (shared-line safe).
  let l = int(line)
  if l >= 16: return
  var installed = false
  for i in 0 ..< MaxIrqShares:
    if gIrqHandlers[l][i] != nil: installed = true
  for i in 0 ..< MaxIrqShares:
    if gIrqHandlers[l][i] == nil:
      gIrqHandlers[l][i] = handler
      break
  if not installed:
    const entries = [lineEntry(0), lineEntry(1), lineEntry(2), lineEntry(3),
                     lineEntry(4), lineEntry(5), lineEntry(6), lineEntry(7),
                     lineEntry(8), lineEntry(9), lineEntry(10), lineEntry(11),
                     lineEntry(12), lineEntry(13), lineEntry(14), lineEntry(15)]
    discard getInterruptManager().registerExceptionHandler(
      uint32(irqToVector(l)), entries[l])
    picSetLevelTriggered(line)
    picUnmask(line)

proc publishInputEvent(ev: VirtioInputEvent) {.nimcall.} =
  ## Driver → event bus (topic "input"): an input/app server subscribes; the
  ## kernel keeps no input policy. Payload = the 8-byte virtio input event.
  var e = ev
  eventPublish("input", addr e, sizeof(e))

proc initVirtioDevices*() =
  ## PCI scan + virtio device probing; interrupts wired per (shared) line.
  pciScan()
  klogInt(llInfo, "[SERVICES] PCI scan: found ", int64(gPciCount))

  if not virtioNetInit():
    klog(llWarn, "[SERVICES] virtio-net: not available")
  else:
    klog(llInfo, "[SERVICES] ✓ virtio-net initialized")
    wirePciIrq(gVirtioNet.irqLine, virtioNetIrqHandler)
    klogInt(llInfo, "[SERVICES] ✓ virtio-net: IRQ line ", int64(gVirtioNet.irqLine))

  if virtioBlkInit():
    klog(llInfo, "[SERVICES] ✓ virtio-blk initialized")
  else:
    klog(llWarn, "[SERVICES] virtio-blk: not available")

  if virtioGpuInit():
    klog(llInfo, "[SERVICES] ✓ virtio-gpu initialized")
  else:
    klog(llWarn, "[SERVICES] virtio-gpu: not available")

  if virtioSndInit():
    klog(llInfo, "[SERVICES] ✓ virtio-snd initialized")
  else:
    klog(llWarn, "[SERVICES] virtio-snd: not available")

  if virtioInputInit():
    gInputOnEvent = publishInputEvent
    for i in 0 ..< gInputCount:                 # the handler drains all devices: wire each distinct line once
      var seen = false
      for k in 0 ..< i:
        if gInputs[k].irqLine == gInputs[i].irqLine: seen = true
      if not seen: wirePciIrq(gInputs[i].irqLine, virtioInputIrqHandler)
    klogInt(llInfo, "[SERVICES] ✓ virtio-input: devices ", int64(gInputCount))
  else:
    klog(llWarn, "[SERVICES] virtio-input: not available")

proc initBuiltinDrivers*() =
  ## Probe VGA, PS2, etc. via driver registry.
  registerDriver(addr ps2KeyboardDriver)
  registerDriver(addr ps2MouseDriver)
  registerDriver(addr vgaTextDriver)
  let (drvOk, drvFail) = probeAllDrivers()
  klog(llInfo, "[SERVICES] ✓ Driver registry probed")
  klogInt(llInfo, "    ok: ", int64(drvOk))
  klogInt(llInfo, "    fail: ", int64(drvFail))

proc initModules*() =
  ## Load kernel modules (filesystems, etc.).
  let (modOk, modFail) = loadAllModules()
  klog(llInfo, "[SERVICES] ✓ Kernel modules loaded")
  klogInt(llInfo, "    ok: ", int64(modOk))
  klogInt(llInfo, "    fail: ", int64(modFail))

# ═══════════════════════════════════════════════════════════════════════════
# Stage 4: IPC Infrastructure
# ═══════════════════════════════════════════════════════════════════════════

proc initIPC*() =
  ## Setup region allocator + ServerChan registry.
  regionAllocInit()
  let testHandle = regionAlloc(4096)
  assert regionValid(testHandle), "regionAlloc test failed"
  regionFree(testHandle)
  klog(llInfo, "[SERVICES] ✓ Region allocator verified")

  serverChanRegistryInit()
  klog(llInfo, "[SERVICES] ✓ ServerChan registry ready")

proc initFilesystems*() =
  ## Register VFS drivers (mounting stays lazy, on first use). Order matters:
  ## the first driver is the default for paths matching no prefix ("/").
  registerFatFs()   # /fat/ and default
  registerRamFs()   # /ram/

# ═══════════════════════════════════════════════════════════════════════════
# Stage 5: Syscall Gate
# ═══════════════════════════════════════════════════════════════════════════

proc initSyscallGate*() =
  ## Wire ring-0 <-> ring-3 syscall dispatch, and the user-fault policy that
  ## comes with ring 3: a CPU fault in a user task kills that task (like exit)
  ## instead of halting the machine — kernel state is intact.
  syscallArgsCheck = kernelUserArgsOk            # ring-3 pointer arguments must stay in the caller's memory
  syscallGateInit()
  installRegionReleaseHook()
  kbufInit()
  userFaultKill   = abiKillFaultingTask
  userStackBounds = abiCurrentTaskBounds
  klog(llInfo, "[SERVICES] ✓ Syscall gate ready (ring 0<->3)")

# ═══════════════════════════════════════════════════════════════════════════
# Stage 6: Boot Services (Ping, FS)
# ═══════════════════════════════════════════════════════════════════════════

proc initPingServer*() =
  ## Spawn ping_server for IPC demo.
  pingServerInit()
  klog(llInfo, "[SERVICES] ✓ Ping server ready")

proc mountFatDisk*(): bool =
  ## Mount FAT filesystem from disk.
  if not fsMount():
    klog(llWarn, "[SERVICES] FAT mount failed")
    return false
  klog(llInfo, "[SERVICES] ✓ FAT volume mounted")
  true


# ═══════════════════════════════════════════════════════════════════════════
# Main Service Initialization Sequence
# ═══════════════════════════════════════════════════════════════════════════

proc initServices*() =
  ## Initialize all services (called after kernel core is ready).
  ##
  ## Stages:
  ##  1. Interrupts + PIC + PIT + Input
  ##  2. Event server + RTC
  ##  3. Virtio devices + driver probing + kernel modules (FAT code)
  ##  4. IPC infrastructure
  ##  5. Syscall gate
  ##
  ## Disk mounting + app loading deferred to shell commands.

  klog(llInfo, "[SERVICES] Starting service initialization")

  # Stage 1
  klog(llInfo, "[SERVICES] Stage 1: Hardware initialization")
  initInterrupts()
  initPIC()
  initTimers()
  initInputDevices()
  enableInterrupts()

  # Stage 2
  klog(llInfo, "[SERVICES] Stage 2: Event system + clock")
  initEventSystem()
  initClock()

  # Stage 3
  klog(llInfo, "[SERVICES] Stage 3: Drivers + I/O")
  initBuiltinDrivers()
  initVirtioDevices()   # devices first: modules (FatFs mount) use them
  if fbConsoleInit():    # from here on, console output also shows on the display
    klog(llInfo, "[SERVICES] ✓ framebuffer console (virtio-gpu)")
  initModules()
  initFilesystems()

  # Stage 4
  klog(llInfo, "[SERVICES] Stage 4: IPC infrastructure")
  initIPC()
  initPingServer()

  # Stage 5
  klog(llInfo, "[SERVICES] Stage 5: Syscall gate")
  initSyscallGate()

  klog(llInfo, "[SERVICES] ✓ Service initialization complete")
