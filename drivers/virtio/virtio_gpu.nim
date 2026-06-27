# SPDX-License-Identifier: GPL-2.0
## Virtio-GPU dumb-framebuffer driver (virtio spec 5.7).
##
## Drives a single 2D resource bound to scanout 0. The framebuffer is
## a contiguous block of BGRA pixels in a region slot; virtioGpuPresent
## transfers it to the host and flushes it to the display.

import virtio_regs
import virtqueue
import virtio_gpu_cmds
import ../pci/pci_bar
import ../../core/log
import ../../mm/region_allocator

const
  VirtioGpuVendor = 0x1AF4'u16
  VirtioGpuDevice = 0x1050'u16
  DefaultWidth    = 1024'u32
  DefaultHeight   = 768'u32
  GpuResourceId   = 1'u32
  PollLimit       = 1_000_000

type
  VirtioGpu* = object
    mmioBase*:   uint64
    controlq*:   Virtqueue
    width*:      uint32
    height*:     uint32
    fbBase*:     uint64
    fbSize*:     uint32
    resourceId*: uint32
    ready*:      bool
    qMem:        pointer

var gGpu*: VirtioGpu

# ── Command submission ────────────────────────────────────────────────────────

proc gpuSubmitCmd(gpu: var VirtioGpu; cmd: pointer; cmdLen: uint32;
                  resp: pointer; respLen: uint32) =
  ## Post a cmd→resp 2-descriptor chain, kick, and poll the used ring.
  let vq = addr gpu.controlq
  let head = vq.nextFree mod QueueSize.uint16
  let next = (vq.nextFree + 1) mod QueueSize.uint16
  vq.desc[head].bufAddr = cast[uint64](cmd)
  vq.desc[head].len     = cmdLen
  vq.desc[head].flags   = VirtqDescFNext
  vq.desc[head].next    = next
  vq.desc[next].bufAddr = cast[uint64](resp)
  vq.desc[next].len     = respLen
  vq.desc[next].flags   = VirtqDescFWrite
  vq.desc[next].next    = 0

  let availIdx = vq.avail.idx mod QueueSize.uint16
  vq.avail.ring[availIdx] = head
  {.emit: "asm volatile(\"\" ::: \"memory\");".}
  vq.avail.idx  = vq.avail.idx + 1
  vq.nextFree   = vq.nextFree + 2
  virtqueueKick(gpu.controlq)

  var spins = 0
  while gpu.controlq.lastUsed == gpu.controlq.used.idx and spins < PollLimit:
    inc spins
  discard virtqueuePop(gpu.controlq)

# ── Device init helpers ───────────────────────────────────────────────────────

proc doReset(base: uint64) {.inline.} =
  mmioWrite32(base, VirtioRegStatus, 0'u32)

proc setStatusBit(base: uint64; bit: uint32) {.inline.} =
  mmioWrite32(base, VirtioRegStatus, mmioRead32(base, VirtioRegStatus) or bit)

proc bringUpDevice(base: uint64): bool =
  ## Reset + ACK/DRIVER/FEATURES_OK handshake. Returns false on failure.
  if mmioRead32(base, VirtioRegMagic) != VirtioMagic:
    klog(llError, "virtio-gpu: bad magic")
    return false
  doReset(base)
  setStatusBit(base, VirtioStatusAck)
  setStatusBit(base, VirtioStatusDriver)
  mmioWrite32(base, VirtioRegDriverFeatures, 0'u32)
  setStatusBit(base, VirtioStatusFeatOk)
  if (mmioRead32(base, VirtioRegStatus) and VirtioStatusFeatOk) == 0:
    klog(llError, "virtio-gpu: FEATURES_OK not accepted")
    mmioWrite32(base, VirtioRegStatus, VirtioStatusFailed)
    return false
  true

proc queryDisplay(gpu: var VirtioGpu) =
  ## GET_DISPLAY_INFO → adopt scanout 0 size, or fall back to defaults.
  var cmd = mkHdr(GpuCmdGetDisplayInfo)
  var resp: GpuDisplayInfo
  gpuSubmitCmd(gpu, addr cmd, uint32(sizeof(cmd)),
               addr resp, uint32(sizeof(resp)))
  let w = resp.pmodes[0].r.w
  let h = resp.pmodes[0].r.h
  if resp.hdr.cmdType == GpuRespOkDisplayInfo and w != 0 and h != 0:
    gpu.width  = w
    gpu.height = h
  else:
    gpu.width  = DefaultWidth
    gpu.height = DefaultHeight

proc createResource(gpu: var VirtioGpu) =
  var cmd = GpuResourceCreate2d(
    hdr: mkHdr(GpuCmdResourceCreate2d),
    resourceId: GpuResourceId, format: GpuFormatB8G8R8X8Unorm,
    width: gpu.width, height: gpu.height)
  var resp: GpuCtrlHdr
  gpuSubmitCmd(gpu, addr cmd, uint32(sizeof(cmd)),
               addr resp, uint32(sizeof(resp)))

proc attachBacking(gpu: var VirtioGpu) =
  var cmd = GpuAttachBacking(
    hdr: mkHdr(GpuCmdResourceAttachBacking),
    resourceId: GpuResourceId, nrEntries: 1,
    entry: GpuMemEntry(addrLo: gpu.fbBase, length: gpu.fbSize))
  var resp: GpuCtrlHdr
  gpuSubmitCmd(gpu, addr cmd, uint32(sizeof(cmd)),
               addr resp, uint32(sizeof(resp)))

proc setScanout(gpu: var VirtioGpu) =
  var cmd = GpuSetScanout(
    hdr: mkHdr(GpuCmdSetScanout),
    r: fullRect(gpu.width, gpu.height),
    scanoutId: 0, resourceId: GpuResourceId)
  var resp: GpuCtrlHdr
  gpuSubmitCmd(gpu, addr cmd, uint32(sizeof(cmd)),
               addr resp, uint32(sizeof(resp)))

proc allocFramebuffer(gpu: var VirtioGpu): bool =
  ## Reserve a region slot; rings occupy the front, pixels follow.
  let h = regionAlloc(RegionSize)
  if not regionValid(h):
    klog(llError, "virtio-gpu: out of region slots")
    return false
  gpu.qMem    = cast[pointer](regionBase(h))
  gpu.fbBase  = cast[uint64](gpu.qMem) + totalQueueBytes()
  gpu.fbSize  = gpu.width * gpu.height * 4
  true

# ── Public init ──────────────────────────────────────────────────────────────

proc virtioGpuInit*(): bool =
  ## Locate the GPU, negotiate, allocate a framebuffer, bind scanout 0.
  let found = pciVirtioFind(VirtioGpuVendor, VirtioGpuDevice)
  if not found.found:
    klog(llWarn, "virtio-gpu: device not found")
    return false
  let bar = pciBarDecode(found.bus, found.slot, found.fn, 0)
  if bar.kind != barMmio or bar.base == 0:
    klog(llError, "virtio-gpu: BAR0 not MMIO")
    return false

  let base = bar.base
  if not bringUpDevice(base):
    return false

  gGpu.mmioBase   = base
  gGpu.resourceId = GpuResourceId
  queryDisplay(gGpu)
  if not allocFramebuffer(gGpu):
    return false
  gGpu.controlq = virtqueueInit(base, 0, gGpu.qMem)

  createResource(gGpu)
  attachBacking(gGpu)
  setScanout(gGpu)

  setStatusBit(base, VirtioStatusOk)
  gGpu.ready = true
  klog(llInfo, "virtio-gpu: ready")
  true

# ── Presentation ──────────────────────────────────────────────────────────────

proc virtioGpuPresent*() =
  ## Transfer the framebuffer to the host and flush it to the display.
  if not gGpu.ready: return
  var xfer = GpuTransferToHost2d(
    hdr: mkHdr(GpuCmdTransferToHost2d),
    r: fullRect(gGpu.width, gGpu.height),
    offset: 0, resourceId: GpuResourceId)
  var resp1: GpuCtrlHdr
  gpuSubmitCmd(gGpu, addr xfer, uint32(sizeof(xfer)),
               addr resp1, uint32(sizeof(resp1)))
  var flush = GpuResourceFlush(
    hdr: mkHdr(GpuCmdResourceFlush),
    r: fullRect(gGpu.width, gGpu.height),
    resourceId: GpuResourceId)
  var resp2: GpuCtrlHdr
  gpuSubmitCmd(gGpu, addr flush, uint32(sizeof(flush)),
               addr resp2, uint32(sizeof(resp2)))

proc virtioGpuFbPtr*(): ptr UncheckedArray[uint32] =
  ## Typed view of the framebuffer pixels (BGRA, one uint32 per pixel).
  if not gGpu.ready: return nil
  cast[ptr UncheckedArray[uint32]](gGpu.fbBase)

proc virtioGpuClearScreen*(color: uint32) =
  ## Fill every pixel with `color` (BGRA), then present.
  let fb = virtioGpuFbPtr()
  if fb == nil: return
  let pixels = int(gGpu.width * gGpu.height)
  for i in 0..<pixels:
    fb[i] = color
  virtioGpuPresent()
