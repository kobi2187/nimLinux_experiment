# SPDX-License-Identifier: GPL-2.0
## Virtio-net driver — PCI device init, TX/RX queues, IRQ handler.
##
## Implements the legacy virtio 1.0 MMIO interface for network I/O.
## RX queue (index 0): device writes received packets here.
## TX queue (index 1): driver posts outgoing packets here.

import virtio_regs
import virtqueue
import ../pci/pci_bar
import ../pci/pci_config
import ../../core/log
import ../../mm/region_allocator

const
  VirtioVendor*     = 0x1AF4'u16
  VirtioNetDevice*  = 0x1000'u16
  VirtioNetHdrSize* = 12        # sizeof(virtio_net_hdr)
  EthMtu            = 1514
  RxBufSize         = VirtioNetHdrSize + EthMtu
  RxPrePost         = QueueSize div 2
  PciRegIrqLine     = 0x3C'u8

type
  VirtioNetHdr* {.packed.} = object
    flags*:      uint8
    gsoType*:    uint8
    hdrLen*:     uint16
    gsoSize*:    uint16
    csumStart*:  uint16
    csumOffset*: uint16
    numBuffers*: uint16

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

var gVirtioNet*:      VirtioNet
var gVirtioNetReady*: bool

# ── Allocation helpers ───────────────────────────────────────────────────────

proc allocQueueMem(): pointer =
  ## Allocate one region slot (4 MB) for a virtqueue's rings + RX buffers.
  ## Returns the slot base pointer, or nil on failure.
  let h = regionAlloc(RegionSize)
  if not regionValid(h):
    klog(llError, "virtio-net: out of region slots")
    return nil
  cast[pointer](regionBase(h))

# ── Device init sequence ─────────────────────────────────────────────────────

proc doReset(base: uint64) {.inline.} =
  mmioWrite32(base, VirtioRegStatus, 0'u32)

proc setStatusBit(base: uint64; bit: uint32) {.inline.} =
  let cur = mmioRead32(base, VirtioRegStatus)
  mmioWrite32(base, VirtioRegStatus, cur or bit)

proc checkMagic(base: uint64): bool =
  mmioRead32(base, VirtioRegMagic) == VirtioMagic

proc negotiateFeatures(base: uint64): uint32 =
  ## Accept MAC feature if offered; return accepted feature mask.
  let offered = mmioRead32(base, VirtioRegDeviceFeatures)
  let accepted = offered and VirtioNetFMac
  mmioWrite32(base, VirtioRegDriverFeatures, accepted)
  accepted

proc featuresOkSet(base: uint64): bool =
  setStatusBit(base, VirtioStatusFeatOk)
  (mmioRead32(base, VirtioRegStatus) and VirtioStatusFeatOk) != 0

proc readMac(base: uint64; mac: var array[6, uint8]) =
  for i in 0..<6:
    mac[i] = mmioRead8(base, VirtioRegConfig + uint32(i))

proc prePostRxBuffers(vq: var Virtqueue; rxMem: pointer) =
  ## Fill the RX queue with empty receive buffers.
  ## Buffers start at rxMem + totalQueueBytes(), spaced by RxBufSize.
  let bufBase = cast[uint64](rxMem) + totalQueueBytes()
  for i in 0..<RxPrePost:
    let buf = cast[pointer](bufBase + uint64(i) * uint64(RxBufSize))
    discard virtqueueAddBuf(vq, buf, RxBufSize.uint32, true)
  virtqueueKick(vq)

# ── Public init ──────────────────────────────────────────────────────────────

proc virtioNetInit*(): bool =
  ## Locate the virtio-net device, negotiate features, set up queues.
  ## Returns true on success; gVirtioNet / gVirtioNetReady set on success.
  let found = pciVirtioFind(VirtioVendor, VirtioNetDevice)
  if not found.found:
    klog(llWarn, "virtio-net: device not found")
    return false

  let bar = pciBarDecode(found.bus, found.slot, found.fn, 0)
  if bar.kind != barMmio or bar.base == 0:
    klog(llError, "virtio-net: BAR0 not MMIO or missing")
    return false

  let base = bar.base
  klogHex(llInfo, "virtio-net: MMIO base=", base)

  if not checkMagic(base):
    klog(llError, "virtio-net: bad magic — not a virtio MMIO device")
    return false

  doReset(base)
  setStatusBit(base, VirtioStatusAck)
  setStatusBit(base, VirtioStatusDriver)

  discard negotiateFeatures(base)
  if not featuresOkSet(base):
    klog(llError, "virtio-net: FEATURES_OK not accepted")
    mmioWrite32(base, VirtioRegStatus, VirtioStatusFailed)
    return false

  let rxMem = allocQueueMem()
  let txMem = allocQueueMem()
  if rxMem == nil or txMem == nil:
    return false

  gVirtioNet.mmioBase = base
  gVirtioNet.rxMem    = rxMem
  gVirtioNet.txMem    = txMem
  gVirtioNet.rxQueue  = virtqueueInit(base, 0, rxMem)
  gVirtioNet.txQueue  = virtqueueInit(base, 1, txMem)
  gVirtioNet.rxCount  = 0
  gVirtioNet.txCount  = 0
  gVirtioNet.irqLine = pciConfigReadU8(found.bus, found.slot, found.fn, PciRegIrqLine)

  readMac(base, gVirtioNet.mac)
  prePostRxBuffers(gVirtioNet.rxQueue, rxMem)

  setStatusBit(base, VirtioStatusOk)
  gVirtioNetReady = true
  klog(llInfo, "virtio-net: ready")
  true

# ── TX ───────────────────────────────────────────────────────────────────────

proc virtioNetSend*(data: pointer; len: uint32): bool =
  ## Transmit one Ethernet frame. Prepends a zeroed VirtioNetHdr.
  if not gVirtioNetReady:
    return false
  let txBufBase = cast[uint64](gVirtioNet.txMem) + totalQueueBytes()
  let txBuf = cast[ptr UncheckedArray[uint8]](txBufBase)
  # Zero the header
  for i in 0..<VirtioNetHdrSize:
    txBuf[i] = 0
  # Copy payload after header
  let src = cast[ptr UncheckedArray[uint8]](data)
  let total = VirtioNetHdrSize + int(len)
  for i in 0..<int(len):
    txBuf[VirtioNetHdrSize + i] = src[i]
  discard virtqueueAddBuf(gVirtioNet.txQueue, cast[pointer](txBufBase),
                          uint32(total), false)
  virtqueueKick(gVirtioNet.txQueue)
  inc gVirtioNet.txCount
  true

# ── RX ───────────────────────────────────────────────────────────────────────

proc virtioNetRecv*(buf: pointer; maxLen: uint32): int =
  ## Copy the next received frame into buf (skipping virtio header).
  ## Returns byte count (without header), or 0 if nothing ready.
  if not gVirtioNetReady:
    return 0
  let pop = virtqueuePop(gVirtioNet.rxQueue)
  if not pop.found:
    return 0
  let descId = pop.id mod uint32(QueueSize)
  let srcAddr = gVirtioNet.rxQueue.desc[descId].bufAddr
  let totalLen = pop.len
  let payloadLen = if totalLen > uint32(VirtioNetHdrSize):
                     totalLen - uint32(VirtioNetHdrSize)
                   else: 0'u32
  let copyLen = if payloadLen < maxLen: payloadLen else: maxLen
  let src = cast[ptr UncheckedArray[uint8]](srcAddr + uint64(VirtioNetHdrSize))
  let dst = cast[ptr UncheckedArray[uint8]](buf)
  for i in 0..<int(copyLen):
    dst[i] = src[i]
  # Re-post the RX descriptor
  let rxBuf = cast[pointer](srcAddr)
  discard virtqueueAddBuf(gVirtioNet.rxQueue, rxBuf, RxBufSize.uint32, true)
  virtqueueKick(gVirtioNet.rxQueue)
  inc gVirtioNet.rxCount
  int(copyLen)

# ── IRQ handler ──────────────────────────────────────────────────────────────

proc virtioNetIrqHandler*() =
  ## Read and ack InterruptStatus; drain used RX entries.
  if not gVirtioNetReady:
    return
  let base = gVirtioNet.mmioBase
  let status = mmioRead32(base, VirtioRegInterruptStatus)
  mmioWrite32(base, VirtioRegInterruptAck, status)
  # Drain without copying — just count arrivals for stats
  while true:
    let pop = virtqueuePop(gVirtioNet.rxQueue)
    if not pop.found:
      break
    inc gVirtioNet.rxCount

# ── Info ─────────────────────────────────────────────────────────────────────

proc u8ToHex(v: uint8; buf: ptr UncheckedArray[char]; off: int) =
  const HexDigits = "0123456789abcdef"
  buf[off]   = HexDigits[int(v shr 4)]
  buf[off+1] = HexDigits[int(v and 0x0F)]

proc uint64ToDec(v: uint64; buf: ptr UncheckedArray[char]; start: int): int =
  ## Write decimal digits into buf starting at `start`. Returns new offset.
  if v == 0:
    buf[start] = '0'
    return start + 1
  var tmp: array[20, char]
  var n = v
  var tlen = 0
  while n > 0:
    tmp[tlen] = char(ord('0') + int(n mod 10))
    n = n div 10
    inc tlen
  var off = start
  for i in countdown(tlen - 1, 0):
    buf[off] = tmp[i]
    inc off
  off

proc virtioNetInfo*(buf: pointer; len: int): int =
  ## Write MAC + TX/RX counts as human-readable text into buf.
  ## Returns bytes written (no NUL terminator counted).
  if not gVirtioNetReady or len < 64:
    return 0
  let b = cast[ptr UncheckedArray[char]](buf)
  # "MAC: xx:xx:xx:xx:xx:xx\n"
  var off = 0
  b[off] = 'M'; inc off
  b[off] = 'A'; inc off
  b[off] = 'C'; inc off
  b[off] = ':'; inc off
  b[off] = ' '; inc off
  for i in 0..<6:
    u8ToHex(gVirtioNet.mac[i], b, off); off += 2
    if i < 5: b[off] = ':'; inc off
  b[off] = '\n'; inc off
  # "TX: <n>\n"
  b[off] = 'T'; inc off; b[off] = 'X'; inc off
  b[off] = ':'; inc off; b[off] = ' '; inc off
  off = uint64ToDec(gVirtioNet.txCount, b, off)
  b[off] = '\n'; inc off
  # "RX: <n>\n"
  b[off] = 'R'; inc off; b[off] = 'X'; inc off
  b[off] = ':'; inc off; b[off] = ' '; inc off
  off = uint64ToDec(gVirtioNet.rxCount, b, off)
  b[off] = '\n'; inc off
  off
