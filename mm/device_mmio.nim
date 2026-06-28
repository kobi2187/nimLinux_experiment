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

var gMapper: VirtualMemManager   ## live VMM, set once at boot

proc registerDeviceMapper*(vmm: VirtualMemManager) =
  ## Called once during kernel memory init, after initKernelSpace.
  assert vmm != nil, "registerDeviceMapper: nil VMM"
  gMapper = vmm

proc deviceMmioFlags(): set[PageFlags] {.inline.} =
  {pfWritable, pfCacheDisable}

proc roundUpFrames(length: uint64): uint64 {.inline.} =
  (length + FrameSize - 1) and not (FrameSize - 1)

proc mapOnePage(virt: VirtAddr, phys: PhysAddr): bool =
  ## Map a single uncached page; already-mapped counts as success (idempotent).
  let r = gMapper.kernelMapRegion(virt, phys, FrameSize, deviceMmioFlags())
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
