# SPDX-License-Identifier: GPL-2.0
## Device MMIO mapping seam.
##
## Device drivers (virtio-pci, virtio-mmio) need their BAR / cap regions mapped
## into the kernel address space UNCACHED so ordinary pointer stores become real
## MMIO writes. The boot stub only identity-maps low RAM (cached); high PCI BARs
## (~0xFE000000) are unmapped. This module is the single MM-facing seam: boot
## registers the live VirtualMemManager once, drivers call `mapDeviceMmio`.
##
## Mapping is identity (virt == phys) and IDEMPOTENT — re-mapping an already
## mapped page (low identity RAM, or two cap regions sharing a page) succeeds.

import ../core/types
import ./virtual_manager
import ./physical_manager

var gMapper: VirtualMemManager   ## live VMM, set once at boot

proc registerDeviceMapper*(vmm: VirtualMemManager) =
  ## Called once during kernel memory init, after initKernelSpace.
  assert vmm != nil, "registerDeviceMapper: nil VMM"
  gMapper = vmm

proc translatePhys*(virt: pointer): uint64 =
  ## Translate a virtual pointer to a physical address using the registered mapper.
  if gMapper == nil:
    return cast[uint64](virt)
  let r = gMapper.translate(gMapper.kernelSpace, VirtAddr(cast[uint64](virt)))
  if r.isOk:
    uint64(r.value)
  else:
    cast[uint64](virt)

proc deviceMmioFlags(): set[PageFlags] {.inline.} =
  {pfWritable, pfCacheDisable}

proc roundUpFrames(length: uint64): uint64 {.inline.} =
  (length + FrameSize - 1) and not (FrameSize - 1)

proc mapOnePage(virt: VirtAddr, phys: PhysAddr): bool =
  ## Map a single uncached page; already-mapped counts as success (idempotent).
  let r = gMapper.kernelMapPage(virt, phys, deviceMmioFlags())
  r.isOk or r.error == meAlreadyMapped

proc mapDeviceMmio*(phys: PhysAddr, length: uint64): VirtAddr =
  ## Identity-map `length` bytes of device MMIO at `phys`, uncached. Returns the
  ## virtual (== physical) base. Page-by-page so partially-mapped regions are ok.
  assert gMapper != nil, "mapDeviceMmio: mapper not registered"
  assert length > 0, "mapDeviceMmio: zero length"
  let total = roundUpFrames(length)
  var off = 0'u64
  while off < total:
    let ok = mapOnePage(VirtAddr(uint64(phys) + off), phys + off)
    assert ok, "mapDeviceMmio: page map failed"
    off += FrameSize
  VirtAddr(phys)

proc allocDmaPages*(nPages: int): pointer =
  ## Allocate `nPages` contiguous physical frames from physMgr (outside the
  ## boot identity map), map them uncached into the kernel address space, and
  ## return the virtual pointer. Returns nil on failure.
  ## Use for DMA ring buffers that must be cache-coherent with a device.
  assert gMapper != nil, "allocDmaPages: mapper not registered"
  assert nPages > 0, "allocDmaPages: zero pages"
  # Use zoneDma32 (16MB-4GB) — zoneNormal (4GB+) is empty on QEMU 256MB;
  # zoneDma32 has frames well above the 64MB boot identity map.
  let r = gMapper.physMgr.allocContiguous(nPages, zoneDma32)
  if r.isErr: return nil
  let phys = r.value
  # Map uncached first, then zero via the mapped virt address.
  # (phys may be above the boot identity map, so direct cast would be wrong.)
  let virt = mapDeviceMmio(phys, uint64(nPages) * FrameSize)
  let p = cast[ptr UncheckedArray[byte]](virt)
  let sizeBytes = uint64(nPages) * FrameSize
  for i in 0..<sizeBytes: p[i] = 0
  cast[pointer](virt)
