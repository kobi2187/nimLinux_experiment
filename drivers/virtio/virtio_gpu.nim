# SPDX-License-Identifier: GPL-2.0
## Virtio-GPU dumb-framebuffer driver (virtio spec 5.7).
##
## Drives a single 2D resource bound to scanout 0. The framebuffer is
## a contiguous block of BGRA pixels in a region slot; virtioGpuPresent
## transfers it to the host and flushes it to the display.
##
## Init order: PCI (modern virtio-1.0 cap walk) first, MMIO legacy fallback.

import virtio_regs
import virtqueue
import virtio_gpu_cmds
import virtio_pci
import ../pci/pci_bar
import ../pci/pci_config
import ../../core/log
import ../../core/types
import ../../mm/device_mmio
import ../../mm/region_allocator

const
  VirtioGpuVendor  = 0x1AF4'u16
  VirtioGpuDevice  = 0x1050'u16
  DefaultWidth     = 1024'u32
  DefaultHeight    = 768'u32
  GpuResourceId    = 1'u32
  PollLimit        = 1_000_000
  GpuQueuePages    = 3   # desc+avail+used + cmd/resp buffers

type
  GpuPciDev = object
    found*:      bool
    bus*, slot*, fn*: uint8
    caps*:       VirtioCaps
    common*:     ptr VirtioPciCommonCfg
    notifyBase*: uint64
    notifyMult*: uint32

  VirtioGpu* = object
    mmioBase*:   uint64   # non-zero on MMIO path
    controlq*:   Virtqueue
    width*:      uint32
    height*:     uint32
    fbBase*:     uint64
    fbSize*:     uint32
    resourceId*: uint32
    ready*:      bool
    usePci*:     bool
    qMem*:       pointer  # DMA ring memory (alloc via allocDmaPages on PCI path)

var gGpu*:    VirtioGpu
var gGpuDev:  GpuPciDev  # PCI state; own global so blk's gDev is unaffected

# ── PCI adapter procs ({.nimcall.} — reads from gGpuDev) ─────────────────────

proc gpuCfgReader(off: uint8): uint8 {.nimcall.} =
  assert gGpuDev.found, "gpuCfgReader: no device"
  pciConfigReadU8(gGpuDev.bus, gGpuDev.slot, gGpuDev.fn, off)

proc gpuBarBase(barIdx: uint8): uint64 {.nimcall.} =
  assert gGpuDev.found, "gpuBarBase: no device"
  pciBarDecode(gGpuDev.bus, gGpuDev.slot, gGpuDev.fn, int(barIdx)).base

proc gpuMapCap(loc: VirtioCapLoc): uint64 =
  let phys = capAddr(loc, gpuBarBase)
  if phys == 0: return 0
  uint64(mapDeviceMmio(PhysAddr(phys), uint64(loc.length)))

# ── Command submission ────────────────────────────────────────────────────────

proc gpuNotify() =
  if gGpu.usePci:
    let qno = gGpuDev.common.queueNotifyOff
    let at  = notifyAddr(gGpuDev.notifyBase, qno, gGpuDev.notifyMult)
    cast[ptr uint16](at)[] = 0'u16
  else:
    virtqueueKick(gGpu.controlq)

proc gpuSubmitCmd(cmd: pointer; cmdLen: uint32; resp: pointer; respLen: uint32) =
  let vq = addr gGpu.controlq
  let head = vq.nextFree mod QueueSize.uint16
  let next = (vq.nextFree + 1) mod QueueSize.uint16
  let cmdPhys  = if gGpu.usePci: translatePhys(cmd)  else: cast[uint64](cmd)
  let respPhys = if gGpu.usePci: translatePhys(resp) else: cast[uint64](resp)
  vq.desc[head] = VirtqDesc(bufAddr: cmdPhys,  len: cmdLen,  flags: VirtqDescFNext, next: next)
  vq.desc[next] = VirtqDesc(bufAddr: respPhys, len: respLen, flags: VirtqDescFWrite, next: 0)
  let ai = vq.avail.idx mod QueueSize.uint16
  vq.avail.ring[ai] = head
  {.emit: "asm volatile(\"\" ::: \"memory\");".}
  vq.avail.idx = vq.avail.idx + 1
  vq.nextFree  = vq.nextFree + 2
  gpuNotify()
  var spins = 0
  while gGpu.controlq.lastUsed == gGpu.controlq.used.idx and spins < PollLimit:
    inc spins
  discard virtqueuePop(gGpu.controlq)

# ── GPU protocol commands ─────────────────────────────────────────────────────

proc gpuQueryDisplay() =
  var cmd  = mkHdr(GpuCmdGetDisplayInfo)
  var resp: GpuDisplayInfo
  gpuSubmitCmd(addr cmd, uint32(sizeof(cmd)), addr resp, uint32(sizeof(resp)))
  let w = resp.pmodes[0].r.w
  let h = resp.pmodes[0].r.h
  if resp.hdr.cmdType == GpuRespOkDisplayInfo and w != 0 and h != 0:
    gGpu.width  = w
    gGpu.height = h
  else:
    gGpu.width  = DefaultWidth
    gGpu.height = DefaultHeight

proc gpuCreateResource() =
  var cmd = GpuResourceCreate2d(hdr: mkHdr(GpuCmdResourceCreate2d),
    resourceId: GpuResourceId, format: GpuFormatB8G8R8X8Unorm,
    width: gGpu.width, height: gGpu.height)
  var resp: GpuCtrlHdr
  gpuSubmitCmd(addr cmd, uint32(sizeof(cmd)), addr resp, uint32(sizeof(resp)))

proc gpuAttachBacking() =
  let fbPhys = if gGpu.usePci: translatePhys(cast[pointer](gGpu.fbBase))
               else: gGpu.fbBase
  var cmd = GpuAttachBacking(hdr: mkHdr(GpuCmdResourceAttachBacking),
    resourceId: GpuResourceId, nrEntries: 1,
    entry: GpuMemEntry(addrLo: fbPhys, length: gGpu.fbSize))
  var resp: GpuCtrlHdr
  gpuSubmitCmd(addr cmd, uint32(sizeof(cmd)), addr resp, uint32(sizeof(resp)))

proc gpuSetScanout() =
  var cmd = GpuSetScanout(hdr: mkHdr(GpuCmdSetScanout),
    r: fullRect(gGpu.width, gGpu.height), scanoutId: 0, resourceId: GpuResourceId)
  var resp: GpuCtrlHdr
  gpuSubmitCmd(addr cmd, uint32(sizeof(cmd)), addr resp, uint32(sizeof(resp)))

# ── PCI init path ─────────────────────────────────────────────────────────────

proc gpuInitPci(): bool =
  let f = pciVirtioFind(VirtioGpuVendor, VirtioGpuDevice)
  if not f.found:
    klog(llWarn, "virtio-gpu(pci): not found")
    return false
  gGpuDev = GpuPciDev(found: true, bus: f.bus, slot: f.slot, fn: f.fn)
  let caps = walkVirtioCaps(gpuCfgReader)
  if not caps.common.found:
    klog(llError, "virtio-gpu(pci): no COMMON cap")
    return false
  gGpuDev.caps      = caps
  gGpuDev.common    = cast[ptr VirtioPciCommonCfg](gpuMapCap(caps.common))
  gGpuDev.notifyBase = gpuMapCap(caps.notify)
  gGpuDev.notifyMult = caps.notifyOffMultiplier
  if gGpuDev.common == nil or gGpuDev.notifyBase == 0:
    klog(llError, "virtio-gpu(pci): cap map failed")
    return false
  if not commonNegotiate(gGpuDev.common, 0'u64):
    klog(llError, "virtio-gpu(pci): negotiate failed")
    return false
  let mem = allocDmaPages(GpuQueuePages)
  if mem == nil:
    klog(llError, "virtio-gpu(pci): DMA alloc failed")
    return false
  let physBase = translatePhys(mem)
  let q = virtqueueInitNoWire(0, mem)
  if not commonQueueSetup(gGpuDev.common, 0'u16, physBase,
                          physBase + availRingOffset(), physBase + usedRingOffset()):
    klog(llError, "virtio-gpu(pci): queue setup failed")
    return false
  commonSetDriverOk(gGpuDev.common)
  # framebuffer sits after the ring pages
  let fbOffset = totalQueueBytes()
  gGpu = VirtioGpu(usePci: true, qMem: mem,
                   fbBase: cast[uint64](mem) + fbOffset,
                   controlq: q, resourceId: GpuResourceId)
  gpuQueryDisplay()
  gGpu.fbSize = gGpu.width * gGpu.height * 4
  gpuCreateResource()
  gpuAttachBacking()
  gpuSetScanout()
  gGpu.ready = true
  klog(llInfo, "virtio-gpu(pci): ready")
  true

# ── Legacy MMIO init path ─────────────────────────────────────────────────────

proc doReset(base: uint64) {.inline.} =
  mmioWrite32(base, VirtioRegStatus, 0'u32)

proc setStatusBit(base: uint64; bit: uint32) {.inline.} =
  mmioWrite32(base, VirtioRegStatus, mmioRead32(base, VirtioRegStatus) or bit)

proc gpuInitMmio(): bool =
  let f = pciVirtioFind(VirtioGpuVendor, VirtioGpuDevice)
  if not f.found:
    klog(llWarn, "virtio-gpu(mmio): not found")
    return false
  let bar = pciBarDecode(f.bus, f.slot, f.fn, 0)
  if bar.kind != barMmio or bar.base == 0:
    klog(llError, "virtio-gpu(mmio): BAR0 not MMIO")
    return false
  let base = bar.base
  if mmioRead32(base, VirtioRegMagic) != VirtioMagic:
    klog(llError, "virtio-gpu(mmio): bad magic")
    return false
  doReset(base)
  setStatusBit(base, VirtioStatusAck)
  setStatusBit(base, VirtioStatusDriver)
  mmioWrite32(base, VirtioRegDriverFeatures, 0'u32)
  setStatusBit(base, VirtioStatusFeatOk)
  if (mmioRead32(base, VirtioRegStatus) and VirtioStatusFeatOk) == 0:
    klog(llError, "virtio-gpu(mmio): FEATURES_OK not accepted")
    mmioWrite32(base, VirtioRegStatus, VirtioStatusFailed)
    return false
  let mem = cast[pointer](regionBase(regionAlloc(RegionSize)))
  if mem == nil: return false
  let fbOffset = totalQueueBytes()
  gGpu = VirtioGpu(mmioBase: base, usePci: false, qMem: mem,
                   fbBase: cast[uint64](mem) + fbOffset,
                   controlq: virtqueueInit(base, 0, mem),
                   resourceId: GpuResourceId)
  gpuQueryDisplay()
  gGpu.fbSize = gGpu.width * gGpu.height * 4
  gpuCreateResource()
  gpuAttachBacking()
  gpuSetScanout()
  setStatusBit(base, VirtioStatusOk)
  gGpu.ready = true
  klog(llInfo, "virtio-gpu(mmio): ready")
  true

# ── Public init ──────────────────────────────────────────────────────────────

proc virtioGpuInit*(): bool =
  gpuInitPci() or gpuInitMmio()

# ── Presentation ──────────────────────────────────────────────────────────────

proc virtioGpuPresent*() =
  if not gGpu.ready: return
  var xfer = GpuTransferToHost2d(hdr: mkHdr(GpuCmdTransferToHost2d),
    r: fullRect(gGpu.width, gGpu.height), offset: 0, resourceId: GpuResourceId)
  var resp1: GpuCtrlHdr
  gpuSubmitCmd(addr xfer, uint32(sizeof(xfer)), addr resp1, uint32(sizeof(resp1)))
  var flush = GpuResourceFlush(hdr: mkHdr(GpuCmdResourceFlush),
    r: fullRect(gGpu.width, gGpu.height), resourceId: GpuResourceId)
  var resp2: GpuCtrlHdr
  gpuSubmitCmd(addr flush, uint32(sizeof(flush)), addr resp2, uint32(sizeof(resp2)))

proc virtioGpuFbPtr*(): ptr UncheckedArray[uint32] =
  if not gGpu.ready: return nil
  cast[ptr UncheckedArray[uint32]](gGpu.fbBase)

proc virtioGpuClearScreen*(color: uint32) =
  let fb = virtioGpuFbPtr()
  if fb == nil: return
  let pixels = int(gGpu.width * gGpu.height)
  for i in 0..<pixels: fb[i] = color
  virtioGpuPresent()
