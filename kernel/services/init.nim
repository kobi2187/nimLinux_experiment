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
import ../../drivers/pic
import ../../drivers/pit
import ../../drivers/ps2_keyboard
import ../../drivers/ps2_mouse
import ../../drivers/vga_text
import ../../drivers/pci/pci_device
import ../../drivers/rtc
import ../../kern/interrupts
import ../../arch/x86_64/syscall_gate
import ../../fs/fatfs
import ../../shell/shell

when defined(amd64) or defined(x86_64):
  import ../../arch/x86_64/cpu_primitives

when IsMonolithic:
  import ../../fs/fatfs_module
  import ../../fs/lwext4
else:
  discard

var serverLoadBuf: array[512 * 1024, byte]

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

proc initVirtioDevices*() =
  ## PCI scan + virtio-net / virtio-blk probing.
  pciScan()
  klogInt(llInfo, "[SERVICES] PCI scan: found ", int64(gPciCount))

  if not virtioNetInit():
    klog(llWarn, "[SERVICES] virtio-net: not available")
  else:
    klog(llInfo, "[SERVICES] ✓ virtio-net initialized")
    let netIrq = gVirtioNet.irqLine
    picUnmask(netIrq)
    discard getInterruptManager().registerExceptionHandler(
      uint32(irqToVector(int(netIrq))),
      proc(ctx: ptr ExceptionContext) {.nimcall.} =
        virtioNetIrqHandler()
        picEoi(gVirtioNet.irqLine))
    klogInt(llInfo, "[SERVICES] ✓ virtio-net: IRQ wired (", int64(netIrq))
    klog(llInfo, ")")

  if virtioBlkInit():
    klog(llInfo, "[SERVICES] ✓ virtio-blk initialized")
  else:
    klog(llWarn, "[SERVICES] virtio-blk: not available")

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

# ═══════════════════════════════════════════════════════════════════════════
# Stage 5: Syscall Gate
# ═══════════════════════════════════════════════════════════════════════════

proc initSyscallGate*() =
  ## Wire ring-0 <-> ring-3 syscall dispatch.
  syscallGateInit()
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

proc tryLoadServer*(name: cstring): bool =
  ## Read server ELF from disk and spawn ring-3.
  assert name != nil
  assert fsMounted, "disk not mounted"

  let (res, nbytes) = fsReadInto(name, cast[ptr byte](addr serverLoadBuf[0]),
                                        serverLoadBuf.len)
  if res != fOk or nbytes <= 0:
    klog(llWarn, "boot: server ELF not found on disk: ")
    klog(llWarn, name)
    return false

  launchElfBytes(name, cast[ptr byte](addr serverLoadBuf[0]), nbytes)
  klog(llInfo, "boot: server spawned: ")
  klog(llInfo, name)
  true

proc initBootServices*() =
  ## Try to load fs_server from disk (optional).
  if not mountFatDisk():
    klog(llWarn, "[SERVICES] disk mount failed — proceeding without fs_server")
    return

  if tryLoadServer("fs_server.elf"):
    klog(llInfo, "[SERVICES] ✓ fs_server loaded from disk")
  else:
    klog(llWarn, "[SERVICES] fs_server not found on disk")

# ═══════════════════════════════════════════════════════════════════════════
# Main Service Initialization Sequence
# ═══════════════════════════════════════════════════════════════════════════

proc initServices*() =
  ## Initialize all services (called after kernel core is ready).
  ##
  ## Stages:
  ##  1. Interrupts + PIC + PIT + Input
  ##  2. Event server + RTC
  ##  3. Virtio devices + driver probing
  ##  4. IPC infrastructure
  ##  5. Syscall gate
  ##  6. Boot services (ping, fs)

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
  initModules()
  initVirtioDevices()

  # Stage 4
  klog(llInfo, "[SERVICES] Stage 4: IPC infrastructure")
  initIPC()
  initPingServer()

  # Stage 5
  klog(llInfo, "[SERVICES] Stage 5: Syscall gate")
  initSyscallGate()

  # Stage 6
  klog(llInfo, "[SERVICES] Stage 6: Boot services")
  initBootServices()

  klog(llInfo, "[SERVICES] ✓ Service initialization complete")
