# SPDX-License-Identifier: GPL-2.0
## Virtio modern (1.0) PCI transport — implements VirtioTransport via the
## PCI capability walk (virtio spec §4.1.4).
##
## A virtio-pci device advertises its register regions through vendor PCI
## capabilities (cap id 0x09). Each cap names a (bar, offset, length) and a
## cfg_type (COMMON / NOTIFY / ISR / DEVICE). We walk the capability list,
## map each region via pciBarDecode, and drive the device through CommonCfg.
##
## Struct layouts verified against linux/include/uapi/linux/virtio_pci.h
## (see subprojects/virtio-pci/DECISIONS.md V1 survey).

import std/volatile

when defined(virtioDebug):
  import ../../core/log

# ── Capability cfg_type values (spec §4.1.4) ──────────────────────────────────

const
  VIRTIO_PCI_CAP_COMMON_CFG* = 1'u8
  VIRTIO_PCI_CAP_NOTIFY_CFG* = 2'u8
  VIRTIO_PCI_CAP_ISR_CFG*    = 3'u8
  VIRTIO_PCI_CAP_DEVICE_CFG* = 4'u8
  PciCapIdVendor*            = 0x09'u8   ## vendor-specific cap → virtio cap

# ── struct virtio_pci_cap (16 bytes) ──────────────────────────────────────────

type
  VirtioPciCap* {.packed.} = object
    capVndr*:  uint8        ## 0x09 for virtio
    capNext*:  uint8        ## next cap offset in PCI config space
    capLen*:   uint8        ## this cap's length
    cfgType*:  uint8        ## VIRTIO_PCI_CAP_* selector
    bar*:      uint8        ## which BAR holds the region
    id*:       uint8
    padding*:  array[2, uint8]
    offset*:   uint32       ## offset of the region within the BAR
    length*:   uint32       ## length of the region

  VirtioPciNotifyCap* {.packed.} = object
    cap*:                 VirtioPciCap
    notifyOffMultiplier*: uint32

  VirtioPciCommonCfg* {.packed.} = object
    deviceFeatureSelect*: uint32
    deviceFeature*:       uint32
    guestFeatureSelect*:  uint32
    guestFeature*:        uint32
    msixConfig*:          uint16
    numQueues*:           uint16
    deviceStatus*:        uint8
    configGeneration*:    uint8
    queueSelect*:         uint16
    queueSize*:           uint16
    queueMsixVector*:     uint16
    queueEnable*:         uint16
    queueNotifyOff*:      uint16
    queueDescLo*:         uint32
    queueDescHi*:         uint32
    queueAvailLo*:        uint32
    queueAvailHi*:        uint32
    queueUsedLo*:         uint32
    queueUsedHi*:         uint32

# ── Capability walk (spec §4.1.4) ─────────────────────────────────────────────

type
  CfgReader* = proc(off: uint8): uint8 {.nimcall.}
    ## Read one byte of PCI config space at byte offset `off`.

  VirtioCapLoc* = object
    found*:  bool
    bar*:    uint8
    offset*: uint32
    length*: uint32

  VirtioCaps* = object
    common*, notify*, isr*, device*: VirtioCapLoc
    notifyOffMultiplier*: uint32

const
  PciStatusReg   = 0x06'u8   ## status register (low byte holds caps-present bit)
  PciStatusCaps  = 0x10'u8   ## status bit 4: capability list present
  PciCapPtrReg   = 0x34'u8   ## capabilities list pointer

proc rdU32(rd: CfgReader; at: uint8): uint32 =
  ## Little-endian 32-bit read from config space starting at `at`.
  for i in 0'u8 ..< 4'u8:
    result = result or (uint32(rd(at + i)) shl (i.uint32 * 8))

proc readCapLoc(rd: CfgReader; at: uint8): VirtioCapLoc =
  ## Decode a virtio_pci_cap's (bar, offset, length) at config offset `at`.
  VirtioCapLoc(found: true, bar: rd(at + 4),
               offset: rdU32(rd, at + 8), length: rdU32(rd, at + 12))

proc storeCap(caps: var VirtioCaps; rd: CfgReader; at, cfgType: uint8) =
  case cfgType
  of VIRTIO_PCI_CAP_COMMON_CFG: caps.common = readCapLoc(rd, at)
  of VIRTIO_PCI_CAP_NOTIFY_CFG:
    caps.notify = readCapLoc(rd, at)
    caps.notifyOffMultiplier = rdU32(rd, at + 16)
  of VIRTIO_PCI_CAP_ISR_CFG:    caps.isr = readCapLoc(rd, at)
  of VIRTIO_PCI_CAP_DEVICE_CFG: caps.device = readCapLoc(rd, at)
  else: discard

proc walkVirtioCaps*(rd: CfgReader): VirtioCaps =
  ## Traverse the PCI capability list, recording each virtio cap by cfg_type.
  if (rd(PciStatusReg) and PciStatusCaps) == 0: return
  var at = rd(PciCapPtrReg)
  while at != 0:
    if rd(at) == PciCapIdVendor:
      storeCap(result, rd, at, rd(at + 3))
    at = rd(at + 1)   # cap_next

# ── Region addressing ─────────────────────────────────────────────────────────

type BarBaseFn* = proc(barIndex: uint8): uint64 {.nimcall.}
  ## Return the absolute base address of BAR `barIndex` (0 if absent).

proc capAddr*(loc: VirtioCapLoc; barBase: BarBaseFn): uint64 =
  ## Absolute MMIO address of a cap region: its BAR's base + the cap offset.
  if not loc.found: return 0
  let base = barBase(loc.bar)
  if base == 0: return 0
  base + uint64(loc.offset)

# ── CommonCfg operations (spec §4.1.4.3) ──────────────────────────────────────
# `cfg` points at the device's mapped CommonCfg MMIO window (or a plain struct in
# host tests). Every access MUST go through cfgGet/cfgSet: an uncached mapping
# stops the CPU caching, not the compiler reordering, merging or dropping plain
# stores. (A plain-store queueSetup compiled to enable-before-avail/used, so the
# device latched avail=used=0 and never serviced a request — DECISIONS V10b.)

template cfgGet*(cfg: ptr VirtioPciCommonCfg; field: untyped): untyped =
  ## Volatile read of one CommonCfg register.
  volatileLoad(addr cfg[].field)

template cfgSet*(cfg: ptr VirtioPciCommonCfg; field: untyped; val: typed) =
  ## Volatile write of one CommonCfg register, in program order.
  volatileStore(addr cfg[].field, typeof(cfg[].field)(val))

const
  StatusAck     = 1'u8
  StatusDriver  = 2'u8
  StatusDriverOk = 4'u8
  StatusFeatOk  = 8'u8
  VirtioFVersion1* = 1'u64 shl 32   ## bit 32: modern (virtio-1.0) device

proc lo32(v: uint64): uint32 {.inline.} = uint32(v and 0xFFFFFFFF'u64)
proc hi32(v: uint64): uint32 {.inline.} = uint32(v shr 32)

proc writeGuestFeatures(cfg: ptr VirtioPciCommonCfg; features: uint64) =
  ## Publish both 32-bit feature words (select 0 = low, select 1 = high).
  cfgSet(cfg, guestFeatureSelect, 0); cfgSet(cfg, guestFeature, lo32(features))
  cfgSet(cfg, guestFeatureSelect, 1); cfgSet(cfg, guestFeature, hi32(features))

proc commonNegotiate*(cfg: ptr VirtioPciCommonCfg; features: uint64): bool =
  ## Status handshake: ACK → DRIVER → (accept features) → FEATURES_OK.
  ## VIRTIO_F_VERSION_1 (bit 32) is always offered: a modern device only runs
  ## its virtqueues in 1.0 mode once the driver acks it (spec §3.1.1).
  ## Returns false if the device clears FEATURES_OK (features rejected).
  assert cfg != nil, "negotiate: cfg must be non-nil"
  cfgSet(cfg, deviceStatus, 0)
  cfgSet(cfg, deviceStatus, cfgGet(cfg, deviceStatus) or StatusAck)
  cfgSet(cfg, deviceStatus, cfgGet(cfg, deviceStatus) or StatusDriver)
  writeGuestFeatures(cfg, features or VirtioFVersion1)
  cfgSet(cfg, deviceStatus, cfgGet(cfg, deviceStatus) or StatusFeatOk)
  (cfgGet(cfg, deviceStatus) and StatusFeatOk) != 0

proc commonSetDriverOk*(cfg: ptr VirtioPciCommonCfg) =
  ## Final handshake step: set DRIVER_OK so the device begins servicing the
  ## virtqueues (spec §3.1.1). MUST come AFTER virtqueue setup. Without this the
  ## device accepts buffers (avail.idx advances) but never processes them
  ## (used.idx never moves) — every request times out.
  assert cfg != nil, "setDriverOk: cfg must be non-nil"
  cfgSet(cfg, deviceStatus, cfgGet(cfg, deviceStatus) or StatusDriverOk)

proc commonQueueSetup*(cfg: ptr VirtioPciCommonCfg; idx: uint16;
                       descPhys, availPhys, usedPhys: uint64;
                       ringSize = 0'u16): bool =
  ## Select queue `idx`, set its size (ringSize; 0 = keep the device default),
  ## write the split-ring phys addresses, enable it. False if the device's
  ## max queue size is below ringSize.
  assert cfg != nil, "queueSetup: cfg must be non-nil"
  cfgSet(cfg, queueSelect,  idx)
  # The ring index wraps at queue_size on both sides: state the driver's size
  # (the device default may differ) and refuse a device whose max is smaller.
  if ringSize != 0:
    if cfgGet(cfg, queueSize) < ringSize: return false
    cfgSet(cfg, queueSize, ringSize)
  cfgSet(cfg, queueDescLo,  lo32(descPhys));  cfgSet(cfg, queueDescHi,  hi32(descPhys))
  cfgSet(cfg, queueAvailLo, lo32(availPhys)); cfgSet(cfg, queueAvailHi, hi32(availPhys))
  cfgSet(cfg, queueUsedLo,  lo32(usedPhys));  cfgSet(cfg, queueUsedHi,  hi32(usedPhys))
  cfgSet(cfg, queueEnable,  1)   # last: the device latches the rings on enable
  when defined(virtioDebug):
    klogHex(llInfo, "vblk: numQueues=", uint64(cfgGet(cfg, numQueues)))
    klogHex(llInfo, "vblk: queueSize=", uint64(cfgGet(cfg, queueSize)))
    klogHex(llInfo, "vblk: queueEnable=", uint64(cfgGet(cfg, queueEnable)))
    klogHex(llInfo, "vblk: descPhysWritten=", descPhys)
    klogHex(llInfo, "vblk: status=", uint64(cfgGet(cfg, deviceStatus)))
  true

# ── Notify + device-config access ─────────────────────────────────────────────

proc notifyAddr*(notifyBase: uint64; queueNotifyOff: uint16;
                 notifyOffMultiplier: uint32): uint64 =
  ## Address to write the queue index to in order to kick queue (spec §4.1.4.4):
  ## notify_base + queue_notify_off * notify_off_multiplier.
  notifyBase + uint64(queueNotifyOff) * uint64(notifyOffMultiplier)

proc notifyWrite*(at: uint64; queueIdx: uint16) =
  ## Ring the doorbell. The barrier publishes prior ring stores (plain memory)
  ## before the volatile kick, like Linux virtio_wmb + iowrite16.
  {.emit: "asm volatile(\"\" ::: \"memory\");".}
  volatileStore(cast[ptr uint16](at), queueIdx)

proc commonKick*(cfg: ptr VirtioPciCommonCfg; notifyBase: uint64;
                 notifyOffMultiplier: uint32; queueIdx: uint16) =
  ## Kick queue `queueIdx`. queue_notify_off is per-queue (it reads back for
  ## the SELECTED queue), so select first; the device derives the queue from
  ## the doorbell address, so a stale selection would kick the wrong queue.
  cfgSet(cfg, queueSelect, queueIdx)
  let at = notifyAddr(notifyBase, cfgGet(cfg, queueNotifyOff), notifyOffMultiplier)
  notifyWrite(at, queueIdx)

proc isrRead*(isrBase: uint64): uint8 =
  ## Read (and thereby acknowledge) the ISR status byte. Volatile: a plain
  ## discarded load is dead code to the compiler and would be deleted.
  volatileLoad(cast[ptr uint8](isrBase))

proc deviceConfigRead32*(deviceBase: uint64; off: uint32): uint32 =
  ## Read a 32-bit field from the device-specific config region.
  assert deviceBase != 0, "deviceConfigRead32: device cfg not mapped"
  volatileLoad(cast[ptr uint32](deviceBase + uint64(off)))
