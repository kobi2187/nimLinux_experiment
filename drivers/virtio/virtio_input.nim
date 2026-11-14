# SPDX-License-Identifier: GPL-2.0
## Virtio-input driver (virtio spec 5.8).
##
## Receives keyboard and pointer events from the host, one event queue per device.
## Each event is a (type, code, value) triple — same as Linux evdev. Every
## virtio-input device found is driven (keyboard, mouse, tablet: up to MaxInputs);
## their events merge into one stream through `gInputOnEvent`, and evdev codes
## say what they are (EV_KEY, EV_REL for a mouse, EV_ABS for a tablet).
##
## Designed as an alternative to PS/2 for QEMU. Both can coexist; this driver
## is registered alongside PS/2 and feeds the same event_server.

import virtio_regs
import virtqueue
import virtio_pci
import ../pci/pci_bar
import ../pci/pci_config
import ../pci/pci_device
import ../../core/log
import ../../core/types
import ../../mm/device_mmio

const
  VirtioInputVendor*  = 0x1AF4'u16
  VirtioInputDevice*  = 0x1052'u16
  PciRegIrqLine       = 0x3C'u8
  InQueuePages        = 2
  EvBufCount          = QueueSize div 2  # pre-posted event buffers
  MaxInputs*          = 4

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

var
  gInputs*:   array[MaxInputs, VirtioInput]
  gInputDevs: array[MaxInputs, InputPciDev]
  gInputCount*: int
  gInputInit: int       ## the device being set up (the cap-walk callbacks have no context)
  gInputOnEvent*: proc(ev: VirtioInputEvent) {.nimcall.}
    ## Receives every event of every device as it arrives.

# ── PCI adapter procs ─────────────────────────────────────────────────────────

proc inCfgReader(off: uint8): uint8 {.nimcall.} =
  let d = gInputDevs[gInputInit]
  assert d.found, "inCfgReader: no device"
  pciConfigReadU8(d.bus, d.slot, d.fn, off)

proc inBarBase(barIdx: uint8): uint64 {.nimcall.} =
  let d = gInputDevs[gInputInit]
  assert d.found, "inBarBase: no device"
  pciBarDecode(d.bus, d.slot, d.fn, int(barIdx)).base

proc inMapCap(loc: VirtioCapLoc): uint64 =
  let phys = capAddr(loc, inBarBase)
  if phys == 0: return 0
  uint64(mapDeviceMmio(PhysAddr(phys), uint64(loc.length)))

proc inNotify(i: int; queueIdx: uint16) =
  commonKick(gInputDevs[i].common, gInputDevs[i].notifyBase, gInputDevs[i].notifyMult, queueIdx)

# ── RX buffer pre-post ────────────────────────────────────────────────────────

proc prePostEventBufs(i: int) =
  ## Fill event queue with writable descriptors so the device can deliver events.
  let bufBase = cast[uint64](gInputs[i].qMem) + totalQueueBytes()
  for k in 0..<EvBufCount:
    let buf = cast[pointer](bufBase + uint64(k) * uint64(sizeof(VirtioInputEvent)))
    discard virtqueueAddBuf(gInputs[i].evQueue, buf, uint32(sizeof(VirtioInputEvent)), true)
  inNotify(i, 0)

# ── Public init ──────────────────────────────────────────────────────────────

proc initOne(n: int; f: PciDevice): bool =
  ## Set up the n-th input device (slot n of the tables). False leaves slot n unused.
  gInputInit = n
  gInputDevs[n] = InputPciDev(found: true, bus: f.bus, slot: f.slot, fn: f.fn)
  let caps = walkVirtioCaps(inCfgReader)
  if not caps.common.found:
    klog(llError, "virtio-input: no COMMON cap"); return false
  gInputDevs[n].caps       = caps
  gInputDevs[n].common     = cast[ptr VirtioPciCommonCfg](inMapCap(caps.common))
  gInputDevs[n].notifyBase = inMapCap(caps.notify)
  gInputDevs[n].notifyMult = caps.notifyOffMultiplier
  gInputDevs[n].isrBase    = inMapCap(caps.isr)
  if gInputDevs[n].common == nil or gInputDevs[n].notifyBase == 0:
    klog(llError, "virtio-input: cap map failed"); return false
  if not commonNegotiate(gInputDevs[n].common, 0'u64):
    klog(llError, "virtio-input: negotiate failed"); return false
  let mem = allocDmaPages(InQueuePages)
  if mem == nil:
    klog(llError, "virtio-input: DMA alloc failed"); return false
  let phys = translatePhys(mem)
  gInputs[n].evQueue = virtqueueInitNoWire(0, mem)
  gInputs[n].qMem    = mem
  gInputs[n].irqLine = inCfgReader(PciRegIrqLine)
  cfgSet(gInputDevs[n].common, queueSelect, 0)
  if not pciQueueAttach(gInputDevs[n].common, 0'u16, phys):
    klog(llError, "virtio-input: queue setup failed"); return false
  commonSetDriverOk(gInputDevs[n].common)
  prePostEventBufs(n)
  gInputs[n].ready = true
  true

proc virtioInputInit*(): bool =
  ## Drive every virtio-input device found. True if at least one is ready.
  gInputCount = 0
  for k in 0 ..< MaxInputs:
    let f = pciVirtioFindNth(VirtioInputVendor, VirtioInputDevice, k)
    if not f.found: break
    if initOne(gInputCount, f): inc gInputCount
  if gInputCount == 0:
    klog(llWarn, "virtio-input: not found"); return false
  klogInt(llInfo, "virtio-input: devices ready: ", int64(gInputCount))
  true

# ── IRQ handler ──────────────────────────────────────────────────────────────

proc virtioInputIrqHandler*() =
  ## Drain every device's event queue into gInputOnEvent. The line may be shared (and
  ## the devices may share it), so one call serves all: draining an idle queue is a no-op.
  for i in 0 ..< gInputCount:
    if not gInputs[i].ready: continue
    # Reading ISR acknowledges the (level-triggered, possibly shared) interrupt.
    if gInputDevs[i].isrBase != 0: discard isrRead(gInputDevs[i].isrBase)
    while true:
      let pop = virtqueuePop(gInputs[i].evQueue)
      if not pop.found: break
      let descId  = pop.id mod uint32(QueueSize)
      let bufAddr = gInputs[i].evQueue.desc[descId].bufAddr
      let ev      = cast[ptr VirtioInputEvent](bufAddr)[]
      inc gInputs[i].evCount
      if gInputOnEvent != nil: gInputOnEvent(ev)
      # Re-post the buffer
      discard virtqueueAddBuf(gInputs[i].evQueue, cast[pointer](bufAddr),
                              uint32(sizeof(VirtioInputEvent)), true)
    inNotify(i, 0)
