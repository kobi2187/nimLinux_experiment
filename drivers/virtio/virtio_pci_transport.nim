# SPDX-License-Identifier: GPL-2.0
## VirtioTransport backend over the modern virtio-1.0 PCI capability walk.
##
## Glues `virtio_pci.nim` (cap-walk + CommonCfg ops) and the parent PCI helpers
## (`pciConfigReadU8`, `pciBarDecode`) into the frozen `VirtioTransport` vtable.
## The found device + mapped cap addresses live in module globals because the
## vtable procs are {.nimcall.} (no closure capture) — same pattern as gVirtioBlk.

import virtio_transport
import virtio_pci
import virtio_regs
import virtqueue
import ../pci/pci_bar
import ../pci/pci_config
import ../../core/types
import ../../mm/device_mmio
import ../../core/debug

type
  PciDevLoc = object
    found*: bool
    bus*, slot*, fn*: uint8

  PciMappedDev = object
    loc*:        PciDevLoc
    caps*:       VirtioCaps
    common*:     ptr VirtioPciCommonCfg
    notifyBase*: uint64
    deviceBase*: uint64
    isrBase*:    uint64

var gDev: PciMappedDev   ## the single virtio-pci device this backend drives

# ── kernel adapters ───────────────────────────────────────────────────────────
# CfgReader/BarBaseFn are {.nimcall.}, so they read the found device from gDev.

proc cfgReader(off: uint8): uint8 {.nimcall.} =
  assert gDev.loc.found, "cfgReader: no device located"
  pciConfigReadU8(gDev.loc.bus, gDev.loc.slot, gDev.loc.fn, off)

proc barBase(barIndex: uint8): uint64 {.nimcall.} =
  assert gDev.loc.found, "barBase: no device located"
  pciBarDecode(gDev.loc.bus, gDev.loc.slot, gDev.loc.fn, int(barIndex)).base

# ── mapping cap regions ───────────────────────────────────────────────────────

proc mapCap(loc: VirtioCapLoc): uint64 =
  ## Absolute address of a cap region, uncached-mapped so stores reach the device.
  let phys = capAddr(loc, barBase)
  if phys == 0: return 0
  uint64(mapDeviceMmio(PhysAddr(phys), uint64(loc.length)))

proc mapCaps() =
  ## Resolve + uncached-map each cap region into gDev. Requires gDev.caps set.
  gDev.common     = cast[ptr VirtioPciCommonCfg](mapCap(gDev.caps.common))
  gDev.notifyBase = mapCap(gDev.caps.notify)
  gDev.deviceBase = mapCap(gDev.caps.device)
  gDev.isrBase    = mapCap(gDev.caps.isr)

proc capsResolved(): bool =
  gDev.common != nil and gDev.notifyBase != 0 and gDev.deviceBase != 0

# ── vtable procs ──────────────────────────────────────────────────────────────

proc pciProbe(): bool {.nimcall.} =
  if not gDev.loc.found: return false
  gDev.caps = walkVirtioCaps(cfgReader)
  if not gDev.caps.common.found: return false
  mapCaps()
  earlyPutString("[TRACE probe] common bar="); earlyPutInt(int64(gDev.caps.common.bar))
  earlyPutString(" off="); earlyPutHex(uint64(gDev.caps.common.offset))
  earlyPutString(" -> common(virt)="); earlyPutHex(cast[uint64](gDev.common)); earlyPutString("\n")
  earlyPutString("[TRACE probe] notify bar="); earlyPutInt(int64(gDev.caps.notify.bar))
  earlyPutString(" off="); earlyPutHex(uint64(gDev.caps.notify.offset))
  earlyPutString(" mult="); earlyPutInt(int64(gDev.caps.notifyOffMultiplier))
  earlyPutString(" -> notifyBase="); earlyPutHex(gDev.notifyBase); earlyPutString("\n")
  capsResolved()

proc pciNegotiate(features: uint64): bool {.nimcall.} =
  commonNegotiate(gDev.common, features)

proc pciQueueSetup(idx: uint16; ringPhys: uint64): bool {.nimcall.} =
  ## Split the ring base into desc/avail/used using the shared virtqueue layout,
  ## then set DRIVER_OK so the device starts servicing the queue (spec §3.1.1 —
  ## DRIVER_OK comes after virtqueue setup; without it used.idx never advances).
  if not commonQueueSetup(gDev.common, idx, ringPhys,
                          ringPhys + availRingOffset(), ringPhys + usedRingOffset()):
    return false
  commonSetDriverOk(gDev.common)
  when defined(virtioDebug):
    klogHex(llInfo, "vblk: deviceStatus(after DRIVER_OK)=", uint64(cfgGet(gDev.common, deviceStatus)))
  true

proc pciNotify(idx: uint16) {.nimcall.} =
  let off = gDev.caps.notifyOffMultiplier
  cfgSet(gDev.common, queueSelect, idx)
  let qno = cfgGet(gDev.common, queueNotifyOff)
  let at  = notifyAddr(gDev.notifyBase, qno, off)
  earlyPutString("[TRACE notify] base="); earlyPutHex(gDev.notifyBase)
  earlyPutString(" mult="); earlyPutInt(int64(off))
  earlyPutString(" qNotifyOff="); earlyPutInt(int64(qno))
  earlyPutString(" at="); earlyPutHex(at)
  earlyPutString(" status="); earlyPutHex(uint64(cfgGet(gDev.common, deviceStatus))); earlyPutString("\n")
  notifyWrite(at, idx)
  # Decisive probe: read ISR after the kick. Non-zero ⇒ device acted on the queue.
  if gDev.isrBase != 0:
    let isr = isrRead(gDev.isrBase)
    earlyPutString("[TRACE notify] ISR(post-kick)="); earlyPutHex(uint64(isr)); earlyPutString("\n")

proc pciReadConfig(off: uint32): uint32 {.nimcall.} =
  deviceConfigRead32(gDev.deviceBase, off)

proc pciIrqLine(): uint8 {.nimcall.} =
  cfgReader(0x3C'u8)   ## PCI interrupt-line register

# ── public constructor ────────────────────────────────────────────────────────

proc pciTransport*(vendorId, deviceId: uint16): VirtioTransport =
  ## Locate the device and return a wired VirtioTransport. probe() fails if absent.
  let f = pciVirtioFind(vendorId, deviceId)
  gDev = PciMappedDev(loc: PciDevLoc(found: f.found,
                                     bus: f.bus, slot: f.slot, fn: f.fn))
  VirtioTransport(
    probe: pciProbe, negotiate: pciNegotiate, queueSetup: pciQueueSetup,
    notify: pciNotify, readConfig: pciReadConfig, irqLine: pciIrqLine)
