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
    commonKick(gGpuDev.common, gGpuDev.notifyBase, gGpuDev.notifyMult, 0'u16)
  else:
    virtqueueKick(gGpu.controlq)

proc gpuSubmitCmd(cmd: pointer; cmdLen: uint32; resp: pointer; respLen: uint32): bool =
  ## Submit one control command and wait for its response. False on timeout.
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
  # usedIdx is an acquire load; a plain `used.idx` read could be hoisted out of
  # the loop, "completing" commands before the device wrote their response.
  while vq.lastUsed == usedIdx(vq[]) and spins < PollLimit:
    inc spins
  if vq.lastUsed == usedIdx(vq[]):
    klog(llError, "virtio-gpu: command timed out")
    return false
  discard virtqueuePop(vq[])
  {.emit: "asm volatile(\"\" ::: \"memory\");".}
  true

proc gpuCheck(what: cstring; resp: GpuCtrlHdr): bool =
  ## Every command but GET_DISPLAY_INFO answers OK_NODATA; log anything else.
  if resp.cmdType == GpuRespOkNodata: return true
  klog(llError, what)
  klogHex(llError, "virtio-gpu:   response type=", uint64(resp.cmdType))
  false

# ── GPU protocol commands ─────────────────────────────────────────────────────

proc gpuQueryDisplay() =
  var cmd  = mkHdr(GpuCmdGetDisplayInfo)
  var resp: GpuDisplayInfo
  discard gpuSubmitCmd(addr cmd, uint32(sizeof(cmd)), addr resp, uint32(sizeof(resp)))
  let w = resp.pmodes[0].r.w
  let h = resp.pmodes[0].r.h
  if resp.hdr.cmdType == GpuRespOkDisplayInfo and w != 0 and h != 0:
    gGpu.width  = w
    gGpu.height = h
  else:
    gGpu.width  = DefaultWidth
    gGpu.height = DefaultHeight

proc gpuCreateResource(): bool =
  var cmd = GpuResourceCreate2d(hdr: mkHdr(GpuCmdResourceCreate2d),
    resourceId: GpuResourceId, format: GpuFormatB8G8R8X8Unorm,
    width: gGpu.width, height: gGpu.height)
  var resp: GpuCtrlHdr
  gpuSubmitCmd(addr cmd, uint32(sizeof(cmd)), addr resp, uint32(sizeof(resp))) and
    gpuCheck("virtio-gpu: RESOURCE_CREATE_2D failed", resp)

proc gpuAttachBacking(): bool =
  let fbPhys = if gGpu.usePci: translatePhys(cast[pointer](gGpu.fbBase))
               else: gGpu.fbBase
  var cmd = GpuAttachBacking(hdr: mkHdr(GpuCmdResourceAttachBacking),
    resourceId: GpuResourceId, nrEntries: 1,
    entry: GpuMemEntry(addrLo: fbPhys, length: gGpu.fbSize))
  var resp: GpuCtrlHdr
  gpuSubmitCmd(addr cmd, uint32(sizeof(cmd)), addr resp, uint32(sizeof(resp))) and
    gpuCheck("virtio-gpu: ATTACH_BACKING failed", resp)

proc gpuSetScanout(): bool =
  var cmd = GpuSetScanout(hdr: mkHdr(GpuCmdSetScanout),
    r: fullRect(gGpu.width, gGpu.height), scanoutId: 0, resourceId: GpuResourceId)
  var resp: GpuCtrlHdr
  gpuSubmitCmd(addr cmd, uint32(sizeof(cmd)), addr resp, uint32(sizeof(resp))) and
    gpuCheck("virtio-gpu: SET_SCANOUT failed", resp)

# ── PCI init path ─────────────────────────────────────────────────────────────

proc gpuInitPci(): bool =
  let f = pciVirtioFind(VirtioGpuVendor, VirtioGpuDevice)
  if not f.found:
    klog(llWarn, "virtio-gpu(pci): not found")
    return false
  gGpuDev = GpuPciDev(found: true, bus: f.bus, slot: f.slot, fn: f.fn)
  pciDisableIntx(f.bus, f.slot, f.fn)      # polled driver
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
  if not pciQueueAttach(gGpuDev.common, 0'u16, physBase):
    klog(llError, "virtio-gpu(pci): queue setup failed")
    return false
  commonSetDriverOk(gGpuDev.common)
  gGpu = VirtioGpu(usePci: true, qMem: mem, controlq: q, resourceId: GpuResourceId)
  gpuQueryDisplay()
  gGpu.fbSize = gGpu.width * gGpu.height * 4
  # The framebuffer gets its own contiguous DMA allocation sized from the real
  # mode. It used to sit right after the 3 ring pages: a 1280x800 (4 MB) fb
  # overran ~4 MB of unrelated physical memory on the first draw.
  let fb = allocDmaPages(int((gGpu.fbSize + 4095) div 4096))
  if fb == nil:
    klog(llError, "virtio-gpu(pci): framebuffer alloc failed")
    return false
  gGpu.fbBase = cast[uint64](fb)
  if not (gpuCreateResource() and gpuAttachBacking() and gpuSetScanout()):
    klog(llError, "virtio-gpu(pci): display setup failed")
    return false
  gGpu.ready = true
  klogInt(llInfo, "virtio-gpu(pci): ready, width=", int64(gGpu.width))
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
  if not (gpuCreateResource() and gpuAttachBacking() and gpuSetScanout()):
    klog(llError, "virtio-gpu(mmio): display setup failed")
    return false
  setStatusBit(base, VirtioStatusOk)
  gGpu.ready = true
  klog(llInfo, "virtio-gpu(mmio): ready")
  true

# ── Public init ──────────────────────────────────────────────────────────────

proc virtioGpuInit*(): bool =
  gpuInitPci() or gpuInitMmio()

# ── Presentation ──────────────────────────────────────────────────────────────

proc virtioGpuPresentRect*(x, y, w, h: int) =
  ## Copy one rectangle of the framebuffer to the host and show it. Small
  ## rects keep a text console cheap (a full 1280x800 frame is 4 MB).
  if not gGpu.ready: return
  let x0 = clamp(x, 0, int(gGpu.width))
  let y0 = clamp(y, 0, int(gGpu.height))
  let x1 = clamp(x + w, 0, int(gGpu.width))
  let y1 = clamp(y + h, 0, int(gGpu.height))
  if x1 <= x0 or y1 <= y0: return
  let r = GpuRect(x: uint32(x0), y: uint32(y0), w: uint32(x1 - x0), h: uint32(y1 - y0))
  # offset = where the rect's first pixel lives in the backing store.
  var xfer = GpuTransferToHost2d(hdr: mkHdr(GpuCmdTransferToHost2d), r: r,
    offset: (uint64(y0) * uint64(gGpu.width) + uint64(x0)) * 4, resourceId: GpuResourceId)
  var resp1: GpuCtrlHdr
  if not (gpuSubmitCmd(addr xfer, uint32(sizeof(xfer)), addr resp1, uint32(sizeof(resp1))) and
          gpuCheck("virtio-gpu: TRANSFER_TO_HOST_2D failed", resp1)): return
  var flush = GpuResourceFlush(hdr: mkHdr(GpuCmdResourceFlush), r: r, resourceId: GpuResourceId)
  var resp2: GpuCtrlHdr
  if gpuSubmitCmd(addr flush, uint32(sizeof(flush)), addr resp2, uint32(sizeof(resp2))):
    discard gpuCheck("virtio-gpu: RESOURCE_FLUSH failed", resp2)

proc virtioGpuPresent*() =
  virtioGpuPresentRect(0, 0, int(gGpu.width), int(gGpu.height))

proc virtioGpuFbPtr*(): ptr UncheckedArray[uint32] =
  if not gGpu.ready: return nil
  cast[ptr UncheckedArray[uint32]](gGpu.fbBase)

proc virtioGpuClearScreen*(color: uint32) =
  let fb = virtioGpuFbPtr()
  if fb == nil: return
  let pixels = int(gGpu.width * gGpu.height)
  for i in 0..<pixels: fb[i] = color
  virtioGpuPresent()
