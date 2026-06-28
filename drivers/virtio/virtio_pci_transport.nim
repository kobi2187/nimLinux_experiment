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
when defined(virtioDebug):
  import ../../core/log

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

proc capsResolved(): bool =
  gDev.common != nil and gDev.notifyBase != 0 and gDev.deviceBase != 0

# ── vtable procs ──────────────────────────────────────────────────────────────

proc pciProbe(): bool {.nimcall.} =
  if not gDev.loc.found: return false
  gDev.caps = walkVirtioCaps(cfgReader)
  if not gDev.caps.common.found: return false
  mapCaps()
  capsResolved()

proc pciNegotiate(features: uint64): bool {.nimcall.} =
  commonNegotiate(gDev.common, features)

proc pciQueueSetup(idx: uint16; ringPhys: uint64): bool {.nimcall.} =
  ## Split the ring base into desc/avail/used using the shared virtqueue layout.
  commonQueueSetup(gDev.common, idx, ringPhys,
                   ringPhys + availRingOffset(), ringPhys + usedRingOffset())

proc pciNotify(idx: uint16) {.nimcall.} =
  let off = gDev.caps.notifyOffMultiplier
  let qno = gDev.common.queueNotifyOff
  let at  = notifyAddr(gDev.notifyBase, qno, off)
  when defined(virtioDebug):
    klogHex(llInfo, "vblk: notifyBase=", gDev.notifyBase)
    klogHex(llInfo, "vblk: notifyMult=", uint64(off))
    klogHex(llInfo, "vblk: queueNotifyOff=", uint64(qno))
    klogHex(llInfo, "vblk: notifyAt=", at)
  cast[ptr uint16](at)[] = idx

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
