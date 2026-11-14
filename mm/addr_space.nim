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

type
  SpaceMem* = object
    ## The three pages of one task's tables. 4 KB aligned (the first field carries the alignment, so
    ## the object does, and each table is exactly one page), because CR3 and table entries hold
    ## page-aligned addresses.
    pml4* {.align(4096).}: PageTable
    pdpt*: PageTable
    pd*: PageTable

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

proc spaceSetBlock*(m: ptr SpaceMem; va: uint64; user, writable: bool): bool =
  ## Rights of one arena block in THIS space (buffer ownership). True if the entry changed.
  setBlockRights(addr m.pml4, va, user, writable)

proc spaceAccess*(pml4: ptr PageTable; va: uint64): PageAccess =
  ## What a ring-3 access to va would find: present, user-accessible at every level, writable at
  ## every level. For huge (2 MB) leaves only (the layout used here).
  let l4 = pml4[(va shr 39) and 511]
  if (l4 and PtePresent) == 0: return
  let l3 = tableOf(l4)[(va shr 30) and 511]
  if (l3 and PtePresent) == 0: return
  let pdE = tableOf(l3)[(va shr 21) and 511]
  if (pdE and PtePresent) == 0 or (pdE and PteHuge) == 0: return
  result.present = true
  result.user = (l4 and l3 and pdE and PteUser) != 0
  result.writable = (l4 and l3 and pdE and PteWritable) != 0
