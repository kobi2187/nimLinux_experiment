# SPDX-License-Identifier: GPL-2.0
## Per-task address spaces (S8): each ring-3 task runs on its OWN page tables.
##
## The kernel keeps one master set of tables (the boot identity map plus the windows added to it).
## A task's space is a private PML4 -> PDPT -> PD chain (three pages) that starts as a copy of the
## master and differs in exactly one thing: which user-accessible windows it has. The kernel's
## mappings are in every space (supervisor-only), so interrupts and syscalls run on whatever
## space is loaded; what a ring-3 program can touch is what its own tables say:
##
##   * its own region (the app's code, data, heap, stack),
##   * the arena blocks it currently holds (buffer ownership),
##   * the time page (read-only, in every space).
##
## Everything else, including the other tasks' regions and arena blocks, is present for the kernel
## but has no User bit, so the hardware refuses a ring-3 access: isolation is a property of the page
## tables, not of a per-switch rewrite of shared ones. Virtual addresses stay identical to physical
## ones (the layout the ELF loader, DMA translation and the user-pointer checks already assume);
## decoupling them is a later step this structure allows.
##
## Pure: it walks tables by identity (entry address == pointer), which holds for the boot map and
## for host-test tables. The kernel module (kernel/space/kspace.nim) owns the pool, the switching
## and the lifetime.

import user_window
import region_allocator
import ../ipc/buffers/types

export PageTable

const
  OwnedPdLo* = int(RegionBase div HugePage)
    ## First PD entry whose user rights are per task: the app regions ...
  OwnedPdHi* = int((ArenaBase + uint64(ArenaSize)) div HugePage)
    ## ... and the buffer arena (exclusive). The time page just above is global; everything below
    ## OwnedPdLo and above OwnedPdHi is the kernel's, copied from the master.

const
  ArenaPdLo* = int(ArenaBase div HugePage)
  ArenaPds* = int(uint64(ArenaSize) div HugePage)
  PageSize* = 4096'u64
  PtesPerPd = int(HugePage div PageSize)

type
  SpaceMem* = object
    ## One task's tables: the three pages of the chain plus one page table for each 2 MB step of the
    ## arena, used only where that step is split into 4 KB pages (a buffer that does not fill whole
    ## 2 MB blocks). 4 KB aligned (the first field carries the alignment, so the object does, and each
    ## table is exactly one page), because CR3 and table entries hold page-aligned addresses.
    pml4* {.align(4096).}: PageTable
    pdpt*: PageTable
    pd*: PageTable
    pts*: array[ArenaPds, PageTable]
    regionPt*: PageTable            ## splits ONE 2 MB step of the app's region, to carry the stack's guard page
    guarded*: bool                  ## regionPt is in use

  PageAccess* = tuple[present, user, writable: bool]

proc entryAt(table: ptr PageTable; i: int): ptr uint64 {.inline.} = addr table[i]
proc phys(p: pointer): uint64 {.inline.} = cast[uint64](p)
proc tableOf(entry: uint64): ptr PageTable {.inline.} = cast[ptr PageTable](entry and AddrMask)

proc masterChain(masterPml4: ptr PageTable; pdpt, pd: var ptr PageTable): bool =
  ## The master's PML4[0] -> PDPT[0] -> PD chain, which holds every mapping we care about (the first
  ## 1 GB). False if the master is not shaped like that.
  let l4 = masterPml4[0]
  if (l4 and PtePresent) == 0: return false
  pdpt = tableOf(l4)
  let l3 = pdpt[0]
  if (l3 and PtePresent) == 0 or (l3 and PteHuge) != 0: return false
  pd = tableOf(l3)
  true

proc inOwned(pdIndex: int): bool {.inline.} = pdIndex >= OwnedPdLo and pdIndex < OwnedPdHi

proc spaceBuild*(m: ptr SpaceMem; masterPml4: ptr PageTable): bool =
  ## Make m a private copy of the master with NO user window: every region and arena block is
  ## present for the kernel and invisible to ring 3. The time page keeps the master's rights.
  var mPdpt, mPd: ptr PageTable
  if not masterChain(masterPml4, mPdpt, mPd): return false
  for i in 0 ..< 512:
    m.pml4[i] = masterPml4[i]
    m.pdpt[i] = mPdpt[i]
    m.pd[i] = mPd[i]
  # link the private chain: PML4'[0] -> PDPT', PDPT'[0] -> PD' (kept kernel-only until a window is granted)
  m.pml4[0] = (phys(addr m.pdpt) and AddrMask) or (masterPml4[0] and not (AddrMask or PteUser))
  m.pdpt[0] = (phys(addr m.pd) and AddrMask) or (mPdpt[0] and not (AddrMask or PteUser))
  for i in OwnedPdLo ..< OwnedPdHi:
    m.pd[i] = m.pd[i] and not PteUser          # nothing is a user window until granted
  true

proc spaceSyncKernel*(m: ptr SpaceMem; masterPml4: ptr PageTable) =
  ## The master gained or changed kernel mappings after m was built (a DMA window, a device): copy
  ## them in. The task's own links and its user windows are left alone.
  var mPdpt, mPd: ptr PageTable
  if not masterChain(masterPml4, mPdpt, mPd): return
  for i in 1 ..< 512:
    m.pml4[i] = masterPml4[i]
    m.pdpt[i] = mPdpt[i]
  for i in 0 ..< 512:
    if not inOwned(i): m.pd[i] = mPd[i]

proc spaceRoot*(m: ptr SpaceMem): uint64 = phys(addr m.pml4)
  ## The value to load into CR3.

proc spaceGrantWindow*(m: ptr SpaceMem; base, len: uint64; user: bool): bool =
  ## Open (or close) a 2 MB-aligned window to ring 3 in THIS space only (an app's region).
  setUserWindow(addr m.pml4, base, len, user)

proc leaf(pa: uint64; user, writable: bool; huge: bool): uint64 =
  ## A leaf entry. Kernel access is always allowed (present, writable) unless a user may write less.
  result = pa or PtePresent
  if huge: result = result or PteHuge
  if user: result = result or PteUser
  if writable or not user: result = result or PteWritable

proc spaceSetPages*(m: ptr SpaceMem; va, bytes: uint64; user, writable: bool): bool =
  ## Rights of the arena pages [va, va+bytes) in THIS space (buffer ownership), 4 KB granular.
  ## A 2 MB step that the range covers whole stays (or becomes again) one huge entry, so big buffers
  ## cost no more than before; a step it covers in part is split into a page table and the pages set
  ## one by one; a step whose pages end up all alike is merged back. False if the range is outside the
  ## arena. The caller flushes the TLB afterwards (a split or merge changes more than one page).
  if va mod PageSize != 0 or bytes mod PageSize != 0 or bytes == 0: return false
  if va < ArenaBase or va + bytes > ArenaBase + uint64(ArenaSize): return false
  if user:                                      # parents must let a user leaf through
    m.pml4[0] = m.pml4[0] or PteUser
    m.pdpt[0] = m.pdpt[0] or PteUser
  var cur = va
  let endAt = va + bytes
  while cur < endAt:
    let idx = int(cur div HugePage)
    let stepBase = uint64(idx) * HugePage
    let stepEnd = min(endAt, stepBase + HugePage)
    let whole = cur == stepBase and stepEnd == stepBase + HugePage
    let pt = addr m.pts[idx - ArenaPdLo]
    if whole:
      m.pd[idx] = leaf(stepBase, user, writable, true)
    else:
      if (m.pd[idx] and PteHuge) != 0:          # split: every page inherits the huge entry's rights
        let was = m.pd[idx]
        let u = (was and PteUser) != 0
        let w = (was and PteWritable) != 0
        for i in 0 ..< PtesPerPd:
          pt[i] = leaf(stepBase + uint64(i) * PageSize, u, w, false)
        m.pd[idx] = (phys(pt) and AddrMask) or PtePresent or PteWritable or PteUser
      let first = int((cur - stepBase) div PageSize)
      let last = int((stepEnd - stepBase) div PageSize)
      for i in first ..< last:
        pt[i] = leaf(stepBase + uint64(i) * PageSize, user, writable, false)
      # merge back when all pages are alike
      let e0 = pt[0] - stepBase
      var alike = true
      for i in 1 ..< PtesPerPd:
        if pt[i] - (stepBase + uint64(i) * PageSize) != e0: (alike = false; break)
      if alike:
        m.pd[idx] = leaf(stepBase, (e0 and PteUser) != 0, (e0 and PteWritable) != 0, true)
    cur = stepEnd
  true

proc spaceGuardPage*(m: ptr SpaceMem; va: uint64): bool =
  ## Make ONE 4 KB page of this task's own region unreachable from ring 3 (a stack guard): the 2 MB step
  ## that holds it is split into a page table whose other 511 pages keep the user rights they had, and
  ## this page stays present for the kernel but loses the User bit. At most one guard per space; the step
  ## must currently be a user huge page (the region window, granted). False otherwise; nothing changes then.
  if m.guarded or va mod PageSize != 0 or va < RegionBase or va >= RegionsEnd: return false
  let idx = int(va div HugePage)
  let e = m.pd[idx]
  if (e and PtePresent) == 0 or (e and PteHuge) == 0 or (e and PteUser) == 0: return false
  let stepBase = uint64(idx) * HugePage
  let w = (e and PteWritable) != 0
  for i in 0 ..< PtesPerPd:
    m.regionPt[i] = leaf(stepBase + uint64(i) * PageSize, true, w, false)
  let g = int((va - stepBase) div PageSize)
  m.regionPt[g] = leaf(va, false, true, false)           # present for the kernel, no User bit
  m.pd[idx] = (phys(addr m.regionPt) and AddrMask) or PtePresent or PteWritable or PteUser
  m.guarded = true
  true

proc spaceSetBlock*(m: ptr SpaceMem; va: uint64; user, writable: bool): bool =
  ## One whole 2 MB block (kept for the callers that still think in blocks).
  spaceSetPages(m, va, HugePage, user, writable)

proc spaceAccess*(pml4: ptr PageTable; va: uint64): PageAccess =
  ## What a ring-3 access to va would find: present, user-accessible at every level, writable at
  ## every level. Walks 2 MB leaves and 4 KB page tables.
  let l4 = pml4[(va shr 39) and 511]
  if (l4 and PtePresent) == 0: return
  let l3 = tableOf(l4)[(va shr 30) and 511]
  if (l3 and PtePresent) == 0: return
  let pdE = tableOf(l3)[(va shr 21) and 511]
  if (pdE and PtePresent) == 0: return
  var leafE = pdE
  if (pdE and PteHuge) == 0:                    # split into 4 KB pages: the page entry decides
    leafE = tableOf(pdE)[(va shr 12) and 511]
    if (leafE and PtePresent) == 0: return
  result.present = true
  result.user = (l4 and l3 and pdE and leafE and PteUser) != 0
  result.writable = (l4 and l3 and pdE and leafE and PteWritable) != 0
