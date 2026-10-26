# SPDX-License-Identifier: GPL-2.0
## Virtio-input driver (virtio spec 5.8).
##
## Receives keyboard and pointer events from the host via a single event queue.
## Each event is a (type, code, value) triple — same as Linux evdev.
##
## Designed as an alternative to PS/2 for QEMU. Both can coexist; this driver
## is registered alongside PS/2 and feeds the same event_server.

import virtio_regs
import virtqueue
import virtio_pci
import ../pci/pci_bar
import ../pci/pci_config
import ../../core/log
import ../../core/types
import ../../mm/device_mmio

const
  VirtioInputVendor*  = 0x1AF4'u16
  VirtioInputDevice*  = 0x1052'u16
  PciRegIrqLine       = 0x3C'u8
  InQueuePages        = 2
  EvBufCount          = QueueSize div 2  # pre-posted event buffers

  # evdev event types
  EvSyn*  = 0'u16
  EvKey*  = 1'u16
  EvRel*  = 2'u16
  EvAbs*  = 3'u16

type
  VirtioInputEvent* {.packed.} = object
    typ*:   uint16
    code*:  uint16
    value*: uint32

  InputPciDev = object
    found*:      bool
    bus*, slot*, fn*: uint8
    caps*:       VirtioCaps
    common*:     ptr VirtioPciCommonCfg
    notifyBase*: uint64
    notifyMult*: uint32
    isrBase*:    uint64

  VirtioInput* = object
    evQueue*:  Virtqueue
    qMem*:     pointer
    irqLine*:  uint8
    evCount*:  uint64
    ready*:    bool
    ## Optional callback: set to receive events as they arrive.
    onEvent*:  proc(ev: VirtioInputEvent) {.nimcall.}

var gInput*:    VirtioInput
var gInputDev:  InputPciDev

# ── PCI adapter procs ─────────────────────────────────────────────────────────

proc inCfgReader(off: uint8): uint8 {.nimcall.} =
  assert gInputDev.found, "inCfgReader: no device"
  pciConfigReadU8(gInputDev.bus, gInputDev.slot, gInputDev.fn, off)

proc inBarBase(barIdx: uint8): uint64 {.nimcall.} =
  assert gInputDev.found, "inBarBase: no device"
  pciBarDecode(gInputDev.bus, gInputDev.slot, gInputDev.fn, int(barIdx)).base

proc inMapCap(loc: VirtioCapLoc): uint64 =
  let phys = capAddr(loc, inBarBase)
  if phys == 0: return 0
  uint64(mapDeviceMmio(PhysAddr(phys), uint64(loc.length)))

proc inNotify(queueIdx: uint16) =
  commonKick(gInputDev.common, gInputDev.notifyBase, gInputDev.notifyMult, queueIdx)

# ── RX buffer pre-post ────────────────────────────────────────────────────────

proc prePostEventBufs() =
  ## Fill event queue with writable descriptors so the device can deliver events.
  let bufBase = cast[uint64](gInput.qMem) + totalQueueBytes()
  for i in 0..<EvBufCount:
    let buf = cast[pointer](bufBase + uint64(i) * uint64(sizeof(VirtioInputEvent)))
    discard virtqueueAddBuf(gInput.evQueue, buf, uint32(sizeof(VirtioInputEvent)), true)
  inNotify(0)

# ── Public init ──────────────────────────────────────────────────────────────

proc virtioInputInit*(): bool =
  let f = pciVirtioFind(VirtioInputVendor, VirtioInputDevice)
  if not f.found:
    klog(llWarn, "virtio-input: not found"); return false
  gInputDev = InputPciDev(found: true, bus: f.bus, slot: f.slot, fn: f.fn)
  let caps = walkVirtioCaps(inCfgReader)
  if not caps.common.found:
    klog(llError, "virtio-input: no COMMON cap"); return false
  gInputDev.caps       = caps
  gInputDev.common     = cast[ptr VirtioPciCommonCfg](inMapCap(caps.common))
  gInputDev.notifyBase = inMapCap(caps.notify)
  gInputDev.notifyMult = caps.notifyOffMultiplier
  gInputDev.isrBase    = inMapCap(caps.isr)
  if gInputDev.common == nil or gInputDev.notifyBase == 0:
    klog(llError, "virtio-input: cap map failed"); return false
  if not commonNegotiate(gInputDev.common, 0'u64):
    klog(llError, "virtio-input: negotiate failed"); return false
  let mem = allocDmaPages(InQueuePages)
  if mem == nil:
    klog(llError, "virtio-input: DMA alloc failed"); return false
  let phys = translatePhys(mem)
  gInput.evQueue = virtqueueInitNoWire(0, mem)
  gInput.qMem    = mem
  gInput.irqLine = inCfgReader(PciRegIrqLine)
  cfgSet(gInputDev.common, queueSelect, 0)
  if not pciQueueAttach(gInputDev.common, 0'u16, phys):
    klog(llError, "virtio-input: queue setup failed"); return false
  commonSetDriverOk(gInputDev.common)
  prePostEventBufs()
  gInput.ready = true
  klog(llInfo, "virtio-input: ready")
  true

# ── IRQ handler ──────────────────────────────────────────────────────────────

proc virtioInputIrqHandler*() =
  ## Drain the event queue and dispatch each event to onEvent (if set).
  if not gInput.ready: return
  # Reading ISR acknowledges the (level-triggered, possibly shared) interrupt.
  if gInputDev.isrBase != 0: discard isrRead(gInputDev.isrBase)
  while true:
    let pop = virtqueuePop(gInput.evQueue)
    if not pop.found: break
    let descId  = pop.id mod uint32(QueueSize)
    let bufAddr = gInput.evQueue.desc[descId].bufAddr
    let ev      = cast[ptr VirtioInputEvent](bufAddr)[]
    inc gInput.evCount
    if gInput.onEvent != nil: gInput.onEvent(ev)
    # Re-post the buffer
    discard virtqueueAddBuf(gInput.evQueue, cast[pointer](bufAddr),
                            uint32(sizeof(VirtioInputEvent)), true)
  inNotify(0)
