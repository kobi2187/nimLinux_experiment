# SPDX-License-Identifier: GPL-2.0
## Tests for virtio-pci modern transport — host-side, no hardware.
## Verifies the spec §4.1.4 capability + CommonCfg struct layouts and the
## capability-walk logic against a synthetic config-space buffer.
{.define: noKernelHardware.}

import ../drivers/virtio/virtio_pci
import ../drivers/virtio/virtqueue

# ── Struct layout (virtio spec §4.1.4) ────────────────────────────────────────

proc testVirtioPciCapLayout() =
  ## struct virtio_pci_cap is 16 bytes: cap_vndr,cap_next,cap_len,cfg_type,
  ## bar,id,padding[2],offset(u32),length(u32).
  assert sizeof(VirtioPciCap) == 16, "virtio_pci_cap must be 16 bytes, got " & $sizeof(VirtioPciCap)
  echo "PASS: VirtioPciCap is 16 bytes"

proc testCommonCfgLayout() =
  ## virtio_pci_common_cfg is 56 bytes per spec.
  assert sizeof(VirtioPciCommonCfg) == 56,
    "common_cfg must be 56 bytes, got " & $sizeof(VirtioPciCommonCfg)
  echo "PASS: VirtioPciCommonCfg is 56 bytes"

proc testCfgTypeConsts() =
  assert VIRTIO_PCI_CAP_COMMON_CFG == 1'u8
  assert VIRTIO_PCI_CAP_NOTIFY_CFG == 2'u8
  assert VIRTIO_PCI_CAP_ISR_CFG    == 3'u8
  assert VIRTIO_PCI_CAP_DEVICE_CFG == 4'u8
  echo "PASS: virtio-pci cfg_type constants correct"

# ── Capability walk (V3) ──────────────────────────────────────────────────────
# The walk reads PCI config bytes through an injected reader so it can be tested
# against a synthetic config space with no hardware.

# Synthetic 256-byte PCI config space with a virtio capability chain:
#   status bit 4 set (caps present), cap ptr @0x34 → 0x40
#   @0x40: vendor cap (0x09), cfg_type=COMMON, bar=4, offset=0,    next=0x50
#   @0x50: vendor cap (0x09), cfg_type=NOTIFY, bar=4, offset=0x1000, next=0x60
#   @0x60: vendor cap (0x09), cfg_type=ISR,    bar=4, offset=0x2000, next=0x70
#   @0x70: vendor cap (0x09), cfg_type=DEVICE, bar=4, offset=0x3000, next=0x00
var gCfgSpace: array[256, uint8]

proc synthReader(off: uint8): uint8 {.nimcall.} = gCfgSpace[int(off)]

proc putCap(at: int; cfgType, bar, nextOff: uint8; offset: uint32) =
  gCfgSpace[at]     = PciCapIdVendor   # cap_vndr
  gCfgSpace[at + 1] = nextOff          # cap_next
  gCfgSpace[at + 2] = 16'u8            # cap_len
  gCfgSpace[at + 3] = cfgType          # cfg_type
  gCfgSpace[at + 4] = bar              # bar
  for i in 0 ..< 4: gCfgSpace[at + 8 + i] = uint8((offset shr (i*8)) and 0xFF)

proc buildSynthConfig() =
  for i in 0 ..< 256: gCfgSpace[i] = 0
  gCfgSpace[0x06] = 0x10'u8   # status low byte, bit 4 = caps present
  gCfgSpace[0x34] = 0x40'u8   # capabilities pointer
  putCap(0x40, VIRTIO_PCI_CAP_COMMON_CFG, 4, 0x50, 0)
  putCap(0x50, VIRTIO_PCI_CAP_NOTIFY_CFG, 4, 0x60, 0x1000)
  putCap(0x60, VIRTIO_PCI_CAP_ISR_CFG,    4, 0x70, 0x2000)
  putCap(0x70, VIRTIO_PCI_CAP_DEVICE_CFG, 4, 0x00, 0x3000)

proc testCapWalkFindsAll() =
  buildSynthConfig()
  let caps = walkVirtioCaps(synthReader)
  assert caps.common.found, "COMMON cap must be found"
  assert caps.notify.found, "NOTIFY cap must be found"
  assert caps.isr.found,    "ISR cap must be found"
  assert caps.device.found, "DEVICE cap must be found"
  echo "PASS: cap walk finds all four virtio caps"

proc testCapWalkOffsets() =
  buildSynthConfig()
  let caps = walkVirtioCaps(synthReader)
  assert caps.common.bar == 4,        "common bar"
  assert caps.common.offset == 0,     "common offset"
  assert caps.notify.offset == 0x1000, "notify offset"
  assert caps.device.offset == 0x3000, "device offset"
  echo "PASS: cap walk records correct bar+offset"

proc testCapWalkNoCaps() =
  for i in 0 ..< 256: gCfgSpace[i] = 0   # status bit 4 clear
  let caps = walkVirtioCaps(synthReader)
  assert not caps.common.found, "no caps when status bit 4 clear"
  echo "PASS: cap walk returns nothing when caps absent"

# ── BAR+offset → absolute address (V4) ────────────────────────────────────────

proc testCapAddr() =
  ## capAddr maps a cap region to its absolute MMIO address: barBase + offset.
  let loc = VirtioCapLoc(found: true, bar: 4, offset: 0x1000, length: 0x40)
  # synthetic bar-base lookup: BAR4 lives at 0xFE000000
  proc barBase(idx: uint8): uint64 {.nimcall.} =
    if idx == 4: 0xFE000000'u64 else: 0
  assert capAddr(loc, barBase) == 0xFE001000'u64, "barBase + offset"
  echo "PASS: capAddr = barBase + offset"

proc testCapAddrNotFound() =
  let loc = VirtioCapLoc(found: false)
  proc barBase(idx: uint8): uint64 {.nimcall.} = 0xFE000000'u64
  assert capAddr(loc, barBase) == 0, "absent cap maps to 0"
  echo "PASS: capAddr of absent cap is 0"

# ── CommonCfg negotiate (V5) ──────────────────────────────────────────────────
# Operate on an in-memory CommonCfg; a real device backs the same struct with MMIO.
# For the host test the device "accepts" FEATURES_OK because nothing clears it.

const
  STATUS_ACK     = 1'u8
  STATUS_DRIVER  = 2'u8
  STATUS_FEAT_OK = 8'u8

proc testNegotiateSetsStatus() =
  var cfg: VirtioPciCommonCfg
  let ok = commonNegotiate(addr cfg, 0'u64)
  assert ok, "negotiate must succeed when FEATURES_OK sticks"
  assert (cfg.deviceStatus and STATUS_ACK) != 0,     "ACK set"
  assert (cfg.deviceStatus and STATUS_DRIVER) != 0,  "DRIVER set"
  assert (cfg.deviceStatus and STATUS_FEAT_OK) != 0, "FEATURES_OK set"
  echo "PASS: negotiate drives status ACK→DRIVER→FEATURES_OK"

# ── CommonCfg queueSetup (V6) ─────────────────────────────────────────────────

proc testQueueSetupWritesRingAddrs() =
  var cfg: VirtioPciCommonCfg
  let descPhys  = 0x1122334455667788'u64
  let availPhys = 0x00000000AABBCCDD'u64
  let usedPhys  = 0x0000000011223344'u64
  let ok = commonQueueSetup(addr cfg, 0'u16, descPhys, availPhys, usedPhys)
  assert ok, "queueSetup succeeds"
  assert cfg.queueSelect == 0,             "queue selected"
  assert cfg.queueDescLo == 0x55667788'u32, "desc lo"
  assert cfg.queueDescHi == 0x11223344'u32, "desc hi"
  assert cfg.queueAvailLo == 0xAABBCCDD'u32, "avail lo"
  assert cfg.queueUsedLo == 0x11223344'u32,  "used lo"
  assert cfg.queueEnable == 1,             "queue enabled"
  echo "PASS: queueSetup writes split-ring phys addrs and enables queue"

# ── Notify address (V7) ───────────────────────────────────────────────────────

proc testNotifyAddr() =
  ## notifyAddr = notifyBase + queueNotifyOff * notifyOffMultiplier.
  # notifyBase 0xFE002000, queueNotifyOff=3, multiplier=4 → +12
  assert notifyAddr(0xFE002000'u64, 3'u16, 4'u32) == 0xFE00200C'u64,
    "notify addr with multiplier 4"
  # multiplier 0 → all queues share one notify address (notifyBase)
  assert notifyAddr(0xFE002000'u64, 5'u16, 0'u32) == 0xFE002000'u64,
    "multiplier 0 collapses to base"
  echo "PASS: notifyAddr = base + off * multiplier"

# ── Used-ring completion read (V10 regression) ────────────────────────────────
# Root cause of the V10 disk-read timeout: the spin loop read `vq.used.idx` with
# an ordinary load, which the kernel's -d:danger optimizer hoisted out of the
# loop — so the device's DMA'd completion was never observed. The actual hoist is
# only reproducible against the real device/optimizer (proven by the QEMU boot).
# These host tests guard the *contract that prevents it*: the completion read
# goes through usedIdx(), an acquire load that re-reads memory every call. If
# usedIdx ever reverts to a cached/stale read, testUsedIdxObservesDeviceWrite
# fails (verified by sabotaging usedIdx to cache its first read).

proc bindUsed(vq: var Virtqueue; u: ptr VirtqUsed) =
  ## Point the queue at a caller-owned used ring (no DMA region needed on host).
  vq.used = u
  vq.lastUsed = 0

proc testUsedIdxObservesDeviceWrite() =
  ## usedIdx must reflect a value written to the ring AFTER a prior read of it —
  ## i.e. it re-reads memory, modelling the device's DMA completion.
  var u: VirtqUsed
  var vq: Virtqueue
  bindUsed(vq, addr u)
  u.idx = 0
  assert usedIdx(vq) == 0, "initial used idx"
  u.idx = 1                       # "device" completes a request
  assert usedIdx(vq) == 1, "usedIdx must re-read the device-written idx"
  echo "PASS: usedIdx observes the device-written used index"

proc testPopSeesCompletionAfterEmptyPoll() =
  ## Reproduces the timeout: pop returns empty, then the device bumps used.idx;
  ## the next pop MUST find the completion. Pre-fix (hoisted load) it never did.
  var u: VirtqUsed
  var vq: Virtqueue
  bindUsed(vq, addr u)
  u.idx = 0
  assert not virtqueuePop(vq).found, "empty before any completion"
  u.idx = 1                       # device DMAs a completed descriptor
  u.ring[0] = VirtqUsedElem(id: 7, len: 512)
  let r = virtqueuePop(vq)
  assert r.found and r.id == 7 and r.len == 512, "pop must see the completion"
  echo "PASS: pop sees the completion the device wrote after an empty poll"

when isMainModule:
  testVirtioPciCapLayout()
  testCommonCfgLayout()
  testCfgTypeConsts()
  testCapWalkFindsAll()
  testCapWalkOffsets()
  testCapWalkNoCaps()
  testCapAddr()
  testCapAddrNotFound()
  testNegotiateSetsStatus()
  testQueueSetupWritesRingAddrs()
  testNotifyAddr()
  testUsedIdxObservesDeviceWrite()
  testPopSeesCompletionAfterEmptyPoll()
  echo "All virtio-pci tests passed."
