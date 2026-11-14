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
import ../core/tsc_clock

static: doAssert TimePageAddr == ArenaBase + uint64(ArenaSize),
  "the time page window sits right after the buffer arena"

const TimeWindowSize = 2 * 1024 * 1024'u64      ## one huge page: its own rights, no neighbours

var
  gTimeWindow: bool
    ## The 2 MB time window is reserved and mapped (supervisor-only until published).
  gArenaBlocks*: int
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
  # The time page's window: reserved so the allocator never hands it out, mapped
  # supervisor-only; publishTimePage opens it to user read access. Mandatory:
  # apps read it without asking, so a VM too small to have it (under 226 MB)
  # must fail here, not fault later in every app.
  if gArenaBlocks != ArenaSize div BlockSize or
     pm.reserveRange(TimePageAddr, TimeWindowSize) != TimeWindowSize div 4096 or
     not mapIdentityHuge(pml4, TimePageAddr, TimeWindowSize):
    klog(llError, "memory windows: no room for the time page (needs 226 MB of RAM)")
    return false
  gTimeWindow = true
  flushTlb()
  klogInt(llInfo, "memory windows: regions 32-96 MB reserved; arena blocks=", int64(gArenaBlocks))
  true

proc publishTimePage*(c: TscClock): bool =
  ## Write the clock into the time page and make it readable (never writable)
  ## from ring 3. Once, at boot, before any task runs. False without a window.
  if not gTimeWindow: return false
  let page = cast[ptr TimePage](TimePageAddr)
  page[] = toTimePage(c)                        # supervisor write, rights not yet opened
  let pml4 = cast[ptr PageTable](readCr3() and AddrMask)
  discard setBlockRights(pml4, TimePageAddr, user = true, writable = false)
  flushTlb()
  true
