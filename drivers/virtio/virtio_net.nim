# SPDX-License-Identifier: GPL-2.0
## Virtio-net driver — TX/RX queues, IRQ handler, MAC address.
##
## RX queue (index 0): device writes received packets here.
## TX queue (index 1): driver posts outgoing packets here.
##
## Init order: PCI (modern virtio-1.0 cap walk) first, MMIO legacy fallback.

import virtio_regs
import virtqueue
import virtio_pci
import ../pci/pci_bar
import ../pci/pci_config
import ../../core/log
import ../../core/types
import ../../mm/device_mmio
import ../../mm/region_allocator

const
  VirtioVendor*     = 0x1AF4'u16
  VirtioNetDevice*  = 0x1000'u16
  VirtioNetHdrSize* = 12        # sizeof(virtio_net_hdr)
  EthMtu            = 1514
  RxBufSize         = VirtioNetHdrSize + EthMtu
  RxPrePost         = QueueSize div 2
  PciRegIrqLine     = 0x3C'u8
  NetQueuePages     = 3         # ring + RX/TX buffers per queue

type
  VirtioNetHdr* {.packed.} = object
    flags*:      uint8
    gsoType*:    uint8
    hdrLen*:     uint16
    gsoSize*:    uint16
    csumStart*:  uint16
    csumOffset*: uint16
    numBuffers*: uint16

  NetPciDev = object
    found*:      bool
    bus*, slot*, fn*: uint8
    caps*:       VirtioCaps
    common*:     ptr VirtioPciCommonCfg
    notifyBase*: uint64
    notifyMult*: uint32
    isrBase*:    uint64
    deviceBase*: uint64

  VirtioNet* = object
    mmioBase*:  uint64
    mac*:       array[6, uint8]
    rxQueue*:   Virtqueue
    txQueue*:   Virtqueue
    rxMem*:     pointer
    txMem*:     pointer
    rxCount*:   uint64
    txCount*:   uint64
    irqLine*:   uint8
    usePci*:    bool

var gVirtioNet*:      VirtioNet
var gVirtioNetReady*: bool
var gNetDev:          NetPciDev

# ── PCI adapter procs ({.nimcall.} — reads from gNetDev) ─────────────────────

proc netCfgReader(off: uint8): uint8 {.nimcall.} =
  assert gNetDev.found, "netCfgReader: no device"
  pciConfigReadU8(gNetDev.bus, gNetDev.slot, gNetDev.fn, off)

proc netBarBase(barIdx: uint8): uint64 {.nimcall.} =
  assert gNetDev.found, "netBarBase: no device"
  pciBarDecode(gNetDev.bus, gNetDev.slot, gNetDev.fn, int(barIdx)).base

proc netMapCap(loc: VirtioCapLoc): uint64 =
  let phys = capAddr(loc, netBarBase)
  if phys == 0: return 0
  uint64(mapDeviceMmio(PhysAddr(phys), uint64(loc.length)))

# ── PCI notify/ack helpers ────────────────────────────────────────────────────

proc netNotify(queueIdx: uint16) =
  if gVirtioNet.usePci:
    commonKick(gNetDev.common, gNetDev.notifyBase, gNetDev.notifyMult, queueIdx)
  else:
    if queueIdx == 0: virtqueueKick(gVirtioNet.rxQueue)
    else:             virtqueueKick(gVirtioNet.txQueue)

proc netAckIrq() =
  if gVirtioNet.usePci:
    if gNetDev.isrBase != 0: discard isrRead(gNetDev.isrBase)
  else:
    let base = gVirtioNet.mmioBase
    mmioWrite32(base, VirtioRegInterruptAck, mmioRead32(base, VirtioRegInterruptStatus))

# ── MAC read ─────────────────────────────────────────────────────────────────

proc readMacPci(mac: var array[6, uint8]) =
  ## MAC sits at offset 0 in the device-specific config region.
  if gNetDev.deviceBase == 0: return
  let p = cast[ptr UncheckedArray[uint8]](gNetDev.deviceBase)
  for i in 0..<6: mac[i] = p[i]

proc readMacMmio(base: uint64; mac: var array[6, uint8]) =
  for i in 0..<6:
    mac[i] = mmioRead8(base, VirtioRegConfig + uint32(i))

# ── RX pre-post ──────────────────────────────────────────────────────────────

proc prePostRxBuffers(rxMem: pointer) =
  let bufBase = cast[uint64](rxMem) + totalQueueBytes()
  for i in 0..<RxPrePost:
    let buf = cast[pointer](bufBase + uint64(i) * uint64(RxBufSize))
    discard virtqueueAddBuf(gVirtioNet.rxQueue, buf, RxBufSize.uint32, true)
  netNotify(0)

# ── PCI init path ─────────────────────────────────────────────────────────────

proc netInitPci(): bool =
  let f = pciVirtioFind(VirtioVendor, VirtioNetDevice)
  if not f.found:
    klog(llWarn, "virtio-net(pci): not found")
    return false
  gNetDev = NetPciDev(found: true, bus: f.bus, slot: f.slot, fn: f.fn)
  let caps = walkVirtioCaps(netCfgReader)
  if not caps.common.found:
    klog(llError, "virtio-net(pci): no COMMON cap")
    return false
  gNetDev.caps       = caps
  gNetDev.common     = cast[ptr VirtioPciCommonCfg](netMapCap(caps.common))
  gNetDev.notifyBase = netMapCap(caps.notify)
  gNetDev.notifyMult = caps.notifyOffMultiplier
  gNetDev.isrBase    = netMapCap(caps.isr)
  gNetDev.deviceBase = netMapCap(caps.device)
  if gNetDev.common == nil or gNetDev.notifyBase == 0:
    klog(llError, "virtio-net(pci): cap map failed")
    return false
  if not commonNegotiate(gNetDev.common, uint64(VirtioNetFMac)):
    klog(llError, "virtio-net(pci): negotiate failed")
    return false
  let rxMem = allocDmaPages(NetQueuePages)
  let txMem = allocDmaPages(NetQueuePages)
  if rxMem == nil or txMem == nil:
    klog(llError, "virtio-net(pci): DMA alloc failed")
    return false
  let rxPhys = translatePhys(rxMem)
  let txPhys = translatePhys(txMem)
  let rxq = virtqueueInitNoWire(0, rxMem)
  let txq = virtqueueInitNoWire(1, txMem)
  # Set queue 0 (rx)
  cfgSet(gNetDev.common, queueSelect, 0)
  if not commonQueueSetup(gNetDev.common, 0'u16, rxPhys,
                          rxPhys + availRingOffset(), rxPhys + usedRingOffset()):
    klog(llError, "virtio-net(pci): rxq setup failed"); return false
  # Set queue 1 (tx)
  cfgSet(gNetDev.common, queueSelect, 1)
  if not commonQueueSetup(gNetDev.common, 1'u16, txPhys,
                          txPhys + availRingOffset(), txPhys + usedRingOffset()):
    klog(llError, "virtio-net(pci): txq setup failed"); return false
  commonSetDriverOk(gNetDev.common)
  gVirtioNet = VirtioNet(usePci: true, rxMem: rxMem, txMem: txMem,
                          rxQueue: rxq, txQueue: txq,
                          irqLine: netCfgReader(PciRegIrqLine))
  readMacPci(gVirtioNet.mac)
  prePostRxBuffers(rxMem)
  gVirtioNetReady = true
  klog(llInfo, "virtio-net(pci): ready")
  true

# ── Legacy MMIO init path ─────────────────────────────────────────────────────

proc netInitMmio(): bool =
  let f = pciVirtioFind(VirtioVendor, VirtioNetDevice)
  if not f.found:
    klog(llWarn, "virtio-net(mmio): not found"); return false
  let bar = pciBarDecode(f.bus, f.slot, f.fn, 0)
  if bar.kind != barMmio or bar.base == 0:
    klog(llError, "virtio-net(mmio): BAR0 not MMIO"); return false
  let base = bar.base
  if mmioRead32(base, VirtioRegMagic) != VirtioMagic:
    klog(llError, "virtio-net(mmio): bad magic"); return false
  mmioWrite32(base, VirtioRegStatus, 0'u32)
  mmioWrite32(base, VirtioRegStatus, VirtioStatusAck)
  mmioWrite32(base, VirtioRegStatus, VirtioStatusAck or VirtioStatusDriver)
  let offered = mmioRead32(base, VirtioRegDeviceFeatures)
  mmioWrite32(base, VirtioRegDriverFeatures, offered and VirtioNetFMac)
  mmioWrite32(base, VirtioRegStatus,
    VirtioStatusAck or VirtioStatusDriver or VirtioStatusFeatOk)
  if (mmioRead32(base, VirtioRegStatus) and VirtioStatusFeatOk) == 0:
    klog(llError, "virtio-net(mmio): FEATURES_OK not accepted")
    mmioWrite32(base, VirtioRegStatus, VirtioStatusFailed)
    return false
  let rxMem = cast[pointer](regionBase(regionAlloc(RegionSize)))
  let txMem = cast[pointer](regionBase(regionAlloc(RegionSize)))
  if rxMem == nil or txMem == nil: return false
  gVirtioNet = VirtioNet(mmioBase: base, usePci: false,
                          rxMem: rxMem, txMem: txMem,
                          rxQueue: virtqueueInit(base, 0, rxMem),
                          txQueue: virtqueueInit(base, 1, txMem),
                          irqLine: pciConfigReadU8(f.bus, f.slot, f.fn, PciRegIrqLine))
  readMacMmio(base, gVirtioNet.mac)
  prePostRxBuffers(rxMem)
  mmioWrite32(base, VirtioRegStatus,
    VirtioStatusAck or VirtioStatusDriver or VirtioStatusFeatOk or VirtioStatusOk)
  gVirtioNetReady = true
  klog(llInfo, "virtio-net(mmio): ready")
  true

# ── Public init ──────────────────────────────────────────────────────────────

proc virtioNetInit*(): bool =
  netInitPci() or netInitMmio()

# ── TX ───────────────────────────────────────────────────────────────────────

proc virtioNetSend*(data: pointer; len: uint32): bool =
  if not gVirtioNetReady: return false
  let txBufBase = cast[uint64](gVirtioNet.txMem) + totalQueueBytes()
  let txBuf = cast[ptr UncheckedArray[uint8]](txBufBase)
  for i in 0..<VirtioNetHdrSize: txBuf[i] = 0
  let src = cast[ptr UncheckedArray[uint8]](data)
  for i in 0..<int(len): txBuf[VirtioNetHdrSize + i] = src[i]
  discard virtqueueAddBuf(gVirtioNet.txQueue, cast[pointer](txBufBase),
                          uint32(VirtioNetHdrSize + int(len)), false)
  netNotify(1)
  inc gVirtioNet.txCount
  true

# ── RX ───────────────────────────────────────────────────────────────────────

proc virtioNetRecv*(buf: pointer; maxLen: uint32): int =
  if not gVirtioNetReady: return 0
  let pop = virtqueuePop(gVirtioNet.rxQueue)
  if not pop.found: return 0
  let descId  = pop.id mod uint32(QueueSize)
  let srcAddr = gVirtioNet.rxQueue.desc[descId].bufAddr
  let total   = pop.len
  let payload = if total > uint32(VirtioNetHdrSize): total - uint32(VirtioNetHdrSize) else: 0'u32
  let copyLen = if payload < maxLen: payload else: maxLen
  let src = cast[ptr UncheckedArray[uint8]](srcAddr + uint64(VirtioNetHdrSize))
  let dst = cast[ptr UncheckedArray[uint8]](buf)
  for i in 0..<int(copyLen): dst[i] = src[i]
  discard virtqueueAddBuf(gVirtioNet.rxQueue, cast[pointer](srcAddr), RxBufSize.uint32, true)
  netNotify(0)
  inc gVirtioNet.rxCount
  int(copyLen)

# ── IRQ handler ──────────────────────────────────────────────────────────────

proc virtioNetIrqHandler*() =
  if not gVirtioNetReady: return
  netAckIrq()
  while true:
    let pop = virtqueuePop(gVirtioNet.rxQueue)
    if not pop.found: break
    inc gVirtioNet.rxCount

# ── Info ─────────────────────────────────────────────────────────────────────

proc u8ToHex(v: uint8; buf: ptr UncheckedArray[char]; off: int) =
  const H = "0123456789abcdef"
  buf[off]   = H[int(v shr 4)]
  buf[off+1] = H[int(v and 0x0F)]

proc u64ToDec(v: uint64; buf: ptr UncheckedArray[char]; start: int): int =
  if v == 0: buf[start] = '0'; return start + 1
  var tmp: array[20, char]
  var n = v; var tlen = 0
  while n > 0:
    tmp[tlen] = char(ord('0') + int(n mod 10)); n = n div 10; inc tlen
  var off = start
  for i in countdown(tlen - 1, 0): buf[off] = tmp[i]; inc off
  off

proc virtioNetInfo*(buf: pointer; len: int): int =
  if not gVirtioNetReady or len < 64: return 0
  let b = cast[ptr UncheckedArray[char]](buf)
  var off = 0
  b[off]='M'; inc off; b[off]='A'; inc off; b[off]='C'; inc off
  b[off]=':'; inc off; b[off]=' '; inc off
  for i in 0..<6:
    u8ToHex(gVirtioNet.mac[i], b, off); off += 2
    if i < 5: b[off] = ':'; inc off
  b[off]='\n'; inc off
  b[off]='T'; inc off; b[off]='X'; inc off; b[off]=':'; inc off; b[off]=' '; inc off
  off = u64ToDec(gVirtioNet.txCount, b, off); b[off]='\n'; inc off
  b[off]='R'; inc off; b[off]='X'; inc off; b[off]=':'; inc off; b[off]=' '; inc off
  off = u64ToDec(gVirtioNet.rxCount, b, off); b[off]='\n'; inc off
  off
