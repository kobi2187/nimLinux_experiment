# SPDX-License-Identifier: GPL-2.0
## Virtio-blk driver — PCI device init, single request queue, sync read/write.
##
## Each request is a 3-descriptor chain:
##   [0] BlkReqHdr  — type (read/write), sector number
##   [1] data buf   — device-writable for reads; driver-writable for writes
##   [2] status byte — device writes 0=OK, 1=IOERR, 2=UNSUPP

import virtio_regs
import virtqueue
import virtio_transport
import virtio_pci_transport
import ../pci/pci_bar
import ../pci/pci_config
import ../../core/log
import ../../core/debug
import ../../core/types
import ../../mm/region_allocator
import ../../mm/device_mmio

const
  VirtioBlkDevice* = 0x1001'u16
  VirtioVendorBlk* = 0x1AF4'u16
  BlkSectorSize*   = 512
  BlkReqTypeRead*  = 0'u32
  BlkReqTypeWrite* = 1'u32
  BlkStatusOk*     = 0'u8
  BlkStatusIoErr*  = 1'u8
  BlkStatusUnsupp* = 2'u8
  PciRegIrqLineBlk = 0x3C'u8
  SpinMaxIter      = 5_000_000

type
  BlkReqHdr* {.packed.} = object
    reqType*:  uint32
    reserved*: uint32
    sector*:   uint64

  BlkDmaBufs = object
    hdr*:  ptr BlkReqHdr
    data*: pointer
    stat*: ptr uint8

  VirtioBlk* = object
    mmioBase*:  uint64
    queue*:     Virtqueue
    queueMem*:  pointer
    irqLine*:   uint8
    numSectors*: uint64
    transport*: VirtioTransport   ## set when the device speaks virtio-pci
    usePci*:    bool              ## true → kick via transport, not MMIO

var gVirtioBlk*:      VirtioBlk
var gVirtioBlkReady*: bool

# ── DMA buffer layout ─────────────────────────────────────────────────────────

proc blkDmaBase(): uint64 {.inline.} =
  cast[uint64](gVirtioBlk.queueMem) + totalQueueBytes()

proc blkDmaBufs(): BlkDmaBufs =
  let base = blkDmaBase()
  BlkDmaBufs(
    hdr:  cast[ptr BlkReqHdr](base),
    data: cast[pointer](base + uint64(sizeof(BlkReqHdr))),
    stat: cast[ptr uint8](base + uint64(sizeof(BlkReqHdr)) + uint64(BlkSectorSize))
  )

proc blkFillHdr(b: BlkDmaBufs; sector: uint64; write: bool) =
  b.hdr.reqType  = if write: BlkReqTypeWrite else: BlkReqTypeRead
  b.hdr.reserved = 0
  b.hdr.sector   = sector
  b.stat[]       = 0xFF'u8

# ── Buffer copy helpers ────────────────────────────────────────────────────────

proc copyToDevice(src, dst: pointer) =
  let s = cast[ptr UncheckedArray[uint8]](src)
  let d = cast[ptr UncheckedArray[uint8]](dst)
  for i in 0..<BlkSectorSize: d[i] = s[i]

proc copyFromDevice(src, dst: pointer) =
  let s = cast[ptr UncheckedArray[uint8]](src)
  let d = cast[ptr UncheckedArray[uint8]](dst)
  for i in 0..<BlkSectorSize: d[i] = s[i]

# ── Descriptor chain ──────────────────────────────────────────────────────────

proc blkAllocDesc(vq: ptr Virtqueue): uint16 =
  let idx = vq.nextFree mod QueueSize.uint16
  vq.nextFree = vq.nextFree + 1
  idx

proc blkDescHdr(vq: ptr Virtqueue; b: BlkDmaBufs): uint16 =
  let i = blkAllocDesc(vq)
  vq.desc[i] = VirtqDesc(bufAddr: translatePhys(b.hdr),
                          len: uint32(sizeof(BlkReqHdr)),
                          flags: VirtqDescFNext,
                          next: (i + 1) mod QueueSize.uint16)
  i

proc blkDescData(vq: ptr Virtqueue; b: BlkDmaBufs; write: bool) =
  let i = blkAllocDesc(vq)
  let dataFlags = VirtqDescFNext or (if write: 0'u16 else: VirtqDescFWrite)
  vq.desc[i] = VirtqDesc(bufAddr: translatePhys(b.data),
                          len: BlkSectorSize.uint32,
                          flags: dataFlags,
                          next: (i + 1) mod QueueSize.uint16)

proc blkDescStat(vq: ptr Virtqueue; b: BlkDmaBufs) =
  let i = blkAllocDesc(vq)
  vq.desc[i] = VirtqDesc(bufAddr: translatePhys(b.stat),
                          len: 1'u32,
                          flags: VirtqDescFWrite,
                          next: 0)

proc blkPostChain(vq: ptr Virtqueue; headIdx: uint16) =
  let ai = vq.avail.idx mod QueueSize.uint16
  vq.avail.ring[ai] = headIdx
  {.emit: "asm volatile(\"\" ::: \"memory\");".}
  vq.avail.idx = vq.avail.idx + 1

# ── Completion ────────────────────────────────────────────────────────────────

proc blkReadCap(base: uint64): uint64 =
  let lo = mmioRead32(base, VirtioRegConfig + 0)
  let hi = mmioRead32(base, VirtioRegConfig + 4)
  uint64(lo) or (uint64(hi) shl 32)

proc blkSpinUsed(vq: var Virtqueue): bool =
  var i = 0
  while vq.lastUsed == usedIdx(vq):
    inc i
    if i >= SpinMaxIter: return false
  true

proc blkConsumeUsed(vq: ptr Virtqueue): bool =
  if not blkSpinUsed(vq[]):
    klog(llError, "virtio-blk: request timed out")
    return false
  vq.lastUsed = vq.lastUsed + 1
  true

proc blkKick() =
  ## Notify the device of new buffers — via the PCI transport or legacy MMIO.
  if gVirtioBlk.usePci: gVirtioBlk.transport.notify(0'u16)
  else:                 virtqueueKick(gVirtioBlk.queue)

# ── Device negotiation ────────────────────────────────────────────────────────

proc blkFindMmio(): tuple[ok: bool; base: uint64; irq: uint8] =
  let found = pciVirtioFind(VirtioVendorBlk, VirtioBlkDevice)
  if not found.found:
    klog(llWarn, "virtio-blk: device not found")
    return (false, 0, 0)
  let bar = pciBarDecode(found.bus, found.slot, found.fn, 0)
  if bar.kind != barMmio or bar.base == 0:
    klog(llError, "virtio-blk: BAR0 not MMIO or missing")
    return (false, 0, 0)
  let base = uint64(mapDeviceMmio(PhysAddr(bar.base), bar.size))   # uncached
  let irq = pciConfigReadU8(found.bus, found.slot, found.fn, PciRegIrqLineBlk)
  (true, base, irq)

proc blkNegotiate(base: uint64): bool =
  if mmioRead32(base, VirtioRegMagic) != VirtioMagic:
    klog(llError, "virtio-blk: bad magic"); return false
  mmioWrite32(base, VirtioRegStatus, 0'u32)
  mmioWrite32(base, VirtioRegStatus, VirtioStatusAck)
  mmioWrite32(base, VirtioRegStatus, VirtioStatusAck or VirtioStatusDriver)
  mmioWrite32(base, VirtioRegDriverFeatures, 0'u32)
  mmioWrite32(base, VirtioRegStatus,
    VirtioStatusAck or VirtioStatusDriver or VirtioStatusFeatOk)
  if (mmioRead32(base, VirtioRegStatus) and VirtioStatusFeatOk) == 0:
    klog(llError, "virtio-blk: FEATURES_OK not accepted")
    mmioWrite32(base, VirtioRegStatus, VirtioStatusFailed)
    return false
  true

proc blkAllocQueue(): pointer =
  let h = regionAlloc(RegionSize)
  if not regionValid(h):
    klog(llError, "virtio-blk: out of region slots")
    return nil
  cast[pointer](regionBase(h))

proc blkFinaliseStatus(base: uint64) =
  mmioWrite32(base, VirtioRegStatus,
    VirtioStatusAck or VirtioStatusDriver or VirtioStatusFeatOk or VirtioStatusOk)

# ── PCI (modern virtio-1.0) init path ─────────────────────────────────────────

proc blkPciCapacity(t: VirtioTransport): uint64 =
  ## virtio-blk device-config: capacity (sectors) is a u64 at offset 0.
  uint64(t.readConfig(0)) or (uint64(t.readConfig(4)) shl 32)

proc blkPciReady(t: VirtioTransport): bool =
  ## probe → negotiate; false if the device is absent or rejects features.
  t.probe() and t.negotiate(0'u64)

proc virtioBlkInitPci(): bool =
  var t = pciTransport(VirtioVendorBlk, VirtioBlkDevice)
  if not blkPciReady(t): return false
  let loc = pciVirtioFind(VirtioVendorBlk, VirtioBlkDevice)
  pciDisableIntx(loc.bus, loc.slot, loc.fn)   # polled driver
  # Allocate DMA ring from physMgr (above boot identity map), mapped uncached.
  # Queue needs 2 pages (desc+avail+used=7193B) + DMA bufs. 3 pages = safe margin.
  let mem = allocDmaPages(3)
  if mem == nil:
    klog(llError, "virtio-blk: DMA alloc failed")
    return false
  let physBase = translatePhys(mem)
  let q = virtqueueInitNoWire(0, mem)
  if not t.queueSetup(0'u16, physBase): return false
  gVirtioBlk = VirtioBlk(transport: t, usePci: true, queueMem: mem,
                          irqLine: t.irqLine(), queue: q,
                          numSectors: blkPciCapacity(t))
  gVirtioBlkReady = true
  klogInt(llInfo, "virtio-blk(pci): ready, sectors=", int64(gVirtioBlk.numSectors))
  true

# ── Public init ───────────────────────────────────────────────────────────────

proc virtioBlkInitMmio(): bool =
  let (ok, base, irq) = blkFindMmio()
  if not ok: return false
  if not blkNegotiate(base): return false
  let mem = blkAllocQueue()
  if mem == nil: return false
  gVirtioBlk = VirtioBlk(mmioBase: base, queueMem: mem, irqLine: irq,
                          numSectors: blkReadCap(base),
                          queue: virtqueueInit(base, 0, mem))
  blkFinaliseStatus(base)
  gVirtioBlkReady = true
  klogInt(llInfo, "virtio-blk: ready, sectors=", int64(gVirtioBlk.numSectors))
  true

proc virtioBlkInit*(): bool =
  ## Try the modern virtio-pci transport first, then fall back to legacy MMIO.
  virtioBlkInitPci() or virtioBlkInitMmio()

# ── Read / Write ──────────────────────────────────────────────────────────────

proc virtioBlkRW(sector: uint64; buf: pointer; write: bool): bool =
  if not gVirtioBlkReady: return false
  let b  = blkDmaBufs()
  let vq = addr gVirtioBlk.queue
  # ── Contract traces: DMA layout + ring state ──────────────────────────────
  when defined(virtioTrace):  # -d:virtioTrace: per-request trace
    earlyPutString("[TRACE blkRW] sector="); earlyPutInt(int64(sector))
    earlyPutString(" write="); earlyPutInt(if write: 1 else: 0); earlyPutString("\n")
    earlyPutString("[TRACE blkRW] queueMem(virt)="); earlyPutHex(cast[uint64](gVirtioBlk.queueMem)); earlyPutString("\n")
    earlyPutString("[TRACE blkRW] desc(virt)="); earlyPutHex(cast[uint64](vq.desc))
    earlyPutString(" desc(phys)="); earlyPutHex(translatePhys(vq.desc)); earlyPutString("\n")
    earlyPutString("[TRACE blkRW] hdr(virt)="); earlyPutHex(cast[uint64](b.hdr))
    earlyPutString(" hdr(phys)="); earlyPutHex(translatePhys(b.hdr)); earlyPutString("\n")
    earlyPutString("[TRACE blkRW] usePci="); earlyPutInt(if gVirtioBlk.usePci: 1 else: 0); earlyPutString("\n")
  blkFillHdr(b, sector, write)
  if write: copyToDevice(buf, b.data)
  let head = blkDescHdr(vq, b)
  blkDescData(vq, b, write)
  blkDescStat(vq, b)
  when defined(virtioTrace):  # -d:virtioTrace: per-request trace
    earlyPutString("[TRACE blkRW] descs filled, head="); earlyPutInt(int64(head)); earlyPutString("\n")
    earlyPutString("[TRACE blkRW] avail.idx(pre)="); earlyPutInt(int64(vq.avail.idx)); earlyPutString("\n")
  blkPostChain(vq, head)
  when defined(virtioTrace):  # -d:virtioTrace: per-request trace
    earlyPutString("[TRACE blkRW] posted, avail.idx(post)="); earlyPutInt(int64(vq.avail.idx))
    earlyPutString(" used.idx(pre-kick)="); earlyPutInt(int64(vq.used.idx)); earlyPutString("\n")
  blkKick()
  when defined(virtioTrace):  # -d:virtioTrace: per-request trace
    earlyPutString("[TRACE blkRW] kicked, used.idx(post-kick)="); earlyPutInt(int64(vq.used.idx)); earlyPutString("\n")
    earlyPutString("[TRACE blkRW] spinning for used ring...\n")
  if not blkConsumeUsed(vq):
    when defined(virtioTrace):  # -d:virtioTrace: per-request trace
      earlyPutString("[TRACE blkRW] SPIN TIMED OUT — device never advanced used.idx\n")
    return false
  when defined(virtioTrace):  # -d:virtioTrace: per-request trace
    earlyPutString("[TRACE blkRW] used ring advanced, status="); earlyPutInt(int64(b.stat[])); earlyPutString("\n")
  if b.stat[] != BlkStatusOk:
    klogInt(llError, "virtio-blk: device error, status=", int64(b.stat[]))
    return false
  if not write: copyFromDevice(b.data, buf)
  true

proc virtioBlkRead*(sector: uint64; buf: pointer): bool =
  virtioBlkRW(sector, buf, false)

proc virtioBlkWrite*(sector: uint64; buf: pointer): bool =
  virtioBlkRW(sector, buf, true)
