# SPDX-License-Identifier: GPL-2.0
## Fixed-purpose memory windows: the app regions (32–96 MB) and the buffer
## arena (from 96 MB, ipc/buffers). Both are taken out of the physical
## allocator for good and identity-mapped with 2 MB supervisor pages; user
## access is granted per region (user_window) or per arena block (buffer
## enforcement). Before this, nothing reserved the region range — DMA
## allocations could have landed inside app memory — and regions 8–15 were
## not mapped at all (the boot stub maps only 64 MB).

import physical_manager
import region_allocator
import user_window
import ../core/log
import ../arch/x86_64/cpu_primitives
import ../ipc/buffers/types

var gArenaBlocks*: int
  ## Arena blocks backed by RAM (≤ ArenaSize div BlockSize; fewer on small VMs).

proc reserveArena(pm: PhysicalMemManager): int =
  ## Reserve whole blocks from ArenaBase while RAM lasts.
  const FramesPerBlock = uint64(BlockSize) div 4096
  for i in 0 ..< ArenaSize div BlockSize:
    let base = ArenaBase + uint64(i) * uint64(BlockSize)
    if pm.reserveRange(base, uint64(BlockSize)) != FramesPerBlock: return i
  ArenaSize div BlockSize

proc initMemoryWindows*(pm: PhysicalMemManager): bool =
  ## Call once, after the kernel's final page tables are live.
  let regionFrames = (RegionsEnd - RegionBase) div 4096
  if pm.reserveRange(RegionBase, RegionsEnd - RegionBase) != regionFrames:
    klog(llError, "memory windows: app region range is not free RAM")
    return false
  gArenaBlocks = pm.reserveArena()
  let pml4 = cast[ptr PageTable](readCr3() and AddrMask)
  if not mapIdentityHuge(pml4, RegionBase, RegionsEnd - RegionBase) or
     not mapIdentityHuge(pml4, ArenaBase, uint64(gArenaBlocks) * uint64(BlockSize)):
    klog(llError, "memory windows: identity map failed")
    return false
  flushTlb()
  klogInt(llInfo, "memory windows: regions 32-96 MB reserved; arena blocks=", int64(gArenaBlocks))
  true
