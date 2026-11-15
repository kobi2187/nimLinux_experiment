# SPDX-License-Identifier: GPL-2.0
## Tests for per-task address spaces (mm/addr_space.nim): what ring 3 can reach in each space, that
## spaces and the master do not leak into one another, and that kernel changes reach every space.
import ../mm/addr_space
import ../mm/user_window
import ../mm/region_allocator
import ../ipc/buffers/types

type Master = object
  pml4 {.align(4096).}: PageTable
  pdpt, pd: PageTable

var master: Master
var spaces: array[4, SpaceMem]         # global: statically 4 KB aligned, reachable by identity

const
  TimeIdx = int((ArenaBase + uint64(ArenaSize)) div HugePage)
  Flags = PtePresent or PteWritable

proc initMaster() =
  for i in 0 ..< 512: master.pml4[i] = 0; master.pdpt[i] = 0; master.pd[i] = 0
  master.pml4[0] = (cast[uint64](addr master.pdpt) and AddrMask) or Flags
  master.pdpt[0] = (cast[uint64](addr master.pd) and AddrMask) or Flags
  for i in 0 ..< 128:                                    # identity, 2 MB huge, supervisor-only
    master.pd[i] = (uint64(i) * HugePage) or Flags or PteHuge
  master.pml4[0] = master.pml4[0] or 0                   # parents carry no User bit
  # the time page: user read-only in the master, as publishTimePage leaves it
  master.pd[TimeIdx] = (uint64(TimeIdx) * HugePage) or PtePresent or PteHuge or PteUser
  master.pdpt[1] = 0xABC000'u64 or Flags                 # some other kernel mapping elsewhere
  master.pml4[5] = 0xDEF000'u64 or Flags

proc rp(): ptr PageTable = addr master.pml4
proc sp(i: int): ptr SpaceMem = addr spaces[i]
proc acc(i: int; va: uint64): PageAccess = spaceAccess(addr spaces[i].pml4, va)
proc regionVa(slot: int): uint64 = RegionBase + uint64(slot) * RegionSize
proc blockVa(b: int): uint64 = ArenaBase + uint64(b) * uint64(BlockSize)

proc testBuild() =
  initMaster()
  master.pd[int(regionVa(9) div HugePage)] = master.pd[int(regionVa(9) div HugePage)] or PteUser   # a stale user bit in the master
  assert spaceBuild(sp(0), rp())
  assert spaceRoot(sp(0)) == cast[uint64](addr spaces[0].pml4) and (spaceRoot(sp(0)) and 0xFFF'u64) == 0, "a page-aligned CR3 value"
  # the chain is private: its PML4/PDPT/PD are this space's own pages, not the master's
  assert (spaces[0].pml4[0] and AddrMask) == cast[uint64](addr spaces[0].pdpt)
  assert (spaces[0].pdpt[0] and AddrMask) == cast[uint64](addr spaces[0].pd)
  # the kernel is mapped, supervisor-only
  for va in [0'u64, 4 * HugePage, 15 * HugePage]:
    let a = acc(0, va)
    assert a.present and not a.user, "kernel memory is present for the kernel and invisible to ring 3"
  # every region and every arena block: present, NOT user
  for slot in 0 ..< MaxRegions:
    let a = acc(0, regionVa(slot))
    assert a.present and not a.user, "region " & $slot & " starts closed"
  for b in 0 ..< ArenaSize div BlockSize:
    let a = acc(0, blockVa(b))
    assert a.present and not a.user, "arena block " & $b & " starts closed"
  for i in OwnedPdLo ..< OwnedPdHi:
    assert (spaces[0].pd[i] and PteUser) == 0, "leaf entry " & $i & " has no User bit (even if the master had a stale one)"
  # the time page: user, read-only (parents become User only when a window is granted)
  assert spaceGrantWindow(sp(0), regionVa(0), RegionSize, true)
  for slot in 1 ..< MaxRegions:       # with the parents now open to User, the leaves alone must keep the rest closed
    assert not acc(0, regionVa(slot)).user, "region " & $slot & " stays closed once a neighbour is granted"
  for b in 0 ..< ArenaSize div BlockSize:
    assert not acc(0, blockVa(b)).user, "arena block " & $b & " stays closed once a region is granted"
  let tp = acc(0, uint64(TimeIdx) * HugePage)
  assert tp.present and tp.user and not tp.writable, "time page: read-only to ring 3"
  # other kernel mappings were copied
  assert spaces[0].pml4[5] == master.pml4[5] and spaces[0].pdpt[1] == master.pdpt[1]
  # a malformed master is refused
  var bad: Master
  assert not spaceBuild(sp(1), addr bad.pml4)
  echo "PASS: a new space maps the kernel and every window closed; the time page is read-only"

proc testIsolation() =
  initMaster()
  assert spaceBuild(sp(0), rp()) and spaceBuild(sp(1), rp())
  assert spaceGrantWindow(sp(0), regionVa(3), RegionSize, true)
  assert spaceGrantWindow(sp(1), regionVa(5), RegionSize, true)
  # each space reaches its own region ...
  for off in [0'u64, HugePage]:
    let a = acc(0, regionVa(3) + off)
    assert a.present and a.user and a.writable, "own region is user read-write"
    let b = acc(1, regionVa(5) + off)
    assert b.present and b.user and b.writable
  # ... and not the other's, nor anything else
  for slot in 0 ..< MaxRegions:
    if slot != 3: assert not acc(0, regionVa(slot)).user, "space 0 cannot reach region " & $slot
    if slot != 5: assert not acc(1, regionVa(slot)).user, "space 1 cannot reach region " & $slot
  assert not acc(0, 0'u64).user and not acc(1, 8 * HugePage).user
  # the master never gained a user window: kernel tasks and new spaces start closed
  for slot in 0 ..< MaxRegions:
    assert (master.pd[(regionVa(slot) div HugePage)] and PteUser) == 0, "the master stays supervisor-only"
  assert (master.pml4[0] and PteUser) == 0 and (master.pdpt[0] and PteUser) == 0
  # arena blocks: rights are per space
  assert spaceSetBlock(sp(0), blockVa(7), user = true, writable = true)
  assert acc(0, blockVa(7)).user and acc(0, blockVa(7)).writable
  assert not acc(1, blockVa(7)).user, "a block granted to one space is closed in the other"
  assert spaceSetBlock(sp(1), blockVa(7), user = true, writable = false)
  assert acc(1, blockVa(7)).user and not acc(1, blockVa(7)).writable, "read-only in the other"
  assert acc(0, blockVa(7)).writable, "and still read-write in the first"
  assert spaceSetBlock(sp(0), blockVa(7), user = false, writable = false)
  assert not acc(0, blockVa(7)).user and acc(1, blockVa(7)).user
  # revoking a region closes it
  assert spaceGrantWindow(sp(0), regionVa(3), RegionSize, false)
  assert not acc(0, regionVa(3)).user
  echo "PASS: spaces reach only their own windows; grants never leak into another space or the master"

proc pageVa(b: int; page: int): uint64 = blockVa(b) + uint64(page) * 4096

proc testPages() =
  initMaster()
  assert spaceBuild(sp(0), rp()) and spaceBuild(sp(1), rp())
  assert spaceGrantWindow(sp(0), regionVa(0), RegionSize, true)
  # a victim's page and an attacker's page share one 2 MB block
  assert spaceSetPages(sp(0), pageVa(4, 10), 4096, user = true, writable = true)    # task 0 owns page 10
  assert spaceSetPages(sp(1), pageVa(4, 11), 4096, user = true, writable = true)    # task 1 owns page 11
  assert acc(0, pageVa(4, 10)).user and acc(0, pageVa(4, 10)).writable
  assert not acc(0, pageVa(4, 11)).user, "the neighbouring page is not task 0's"
  assert not acc(1, pageVa(4, 10)).user, "and task 0's page is not task 1's"
  assert acc(1, pageVa(4, 11)).user
  for pg in [0, 9, 12, 511]:
    let a = acc(0, pageVa(4, pg))
    assert a.present and not a.user, "every other page of the block is present for the kernel, closed to ring 3"
  # the block was split: its PD entry points at a page table, and the page entries are exactly these
  let idx = int(blockVa(4) div HugePage)
  assert (spaces[0].pd[idx] and PteHuge) == 0
  let pt = addr spaces[0].pts[idx - ArenaPdLo]
  var userPages = 0
  for i in 0 ..< 512:
    assert (pt[i] and AddrMask) == blockVa(4) + uint64(i) * 4096, "identity kept"
    assert (pt[i] and PtePresent) != 0 and (pt[i] and PteWritable) != 0 or i == 10, "kernel keeps write"
    if (pt[i] and PteUser) != 0: inc userPages
  assert userPages == 1, "exactly one user page in the table"
  # read-only for the user, writable for the kernel's sake only when no user has it
  assert spaceSetPages(sp(0), pageVa(4, 10), 4096, user = true, writable = false)
  assert acc(0, pageVa(4, 10)).user and not acc(0, pageVa(4, 10)).writable
  # a range over many pages and across the block edge into the next block
  assert spaceSetPages(sp(0), pageVa(5, 500), 24 * 4096, user = true, writable = true)   # pages 500..511 of block 5, 0..11 of block 6
  for pg in 500 ..< 512: assert acc(0, pageVa(5, pg)).user
  for pg in 0 ..< 12: assert acc(0, pageVa(6, pg)).user
  assert not acc(0, pageVa(5, 499)).user and not acc(0, pageVa(6, 12)).user, "the range ends exactly"
  # a whole block stays a single huge entry (big buffers cost nothing extra)
  assert spaceSetPages(sp(0), blockVa(8), HugePage, user = true, writable = true)
  assert (spaces[0].pd[int(blockVa(8) div HugePage)] and PteHuge) != 0
  assert acc(0, pageVa(8, 0)).user and acc(0, pageVa(8, 511)).user
  assert spaceSetPages(sp(0), pageVa(8, 5), 4096, user = false, writable = false), "carve a page out of a whole block"
  assert not acc(0, pageVa(8, 5)).user and acc(0, pageVa(8, 4)).user and acc(0, pageVa(8, 6)).user
  # closing the last open page merges the step back into one closed huge entry
  assert spaceSetPages(sp(1), pageVa(4, 11), 4096, user = false, writable = false)
  assert (spaces[1].pd[idx] and PteHuge) != 0 and (spaces[1].pd[idx] and PteUser) == 0, "merged back, closed"
  assert acc(1, pageVa(4, 11)).present and not acc(1, pageVa(4, 11)).user
  # restoring a split block to all-alike pages also merges (carve then refill)
  assert spaceSetPages(sp(0), pageVa(8, 5), 4096, user = true, writable = true)
  assert (spaces[0].pd[int(blockVa(8) div HugePage)] and PteHuge) != 0, "all pages alike again: one huge entry"
  # outside the arena, unaligned or empty: refused, nothing changes
  assert not spaceSetPages(sp(0), ArenaBase - 4096, 4096, true, true)
  assert not spaceSetPages(sp(0), ArenaBase + uint64(ArenaSize), 4096, true, true)
  assert not spaceSetPages(sp(0), ArenaBase + 1, 4096, true, true)
  assert not spaceSetPages(sp(0), ArenaBase, 0, true, true)
  # the master and other spaces never moved
  assert (master.pd[idx] and PteHuge) != 0 and (master.pd[idx] and PteUser) == 0
  assert not acc(1, pageVa(5, 500)).user and not acc(1, pageVa(8, 0)).user
  # exhaustive: for a random sequence of page grants, a model says who can reach what
  var model: array[2, array[3 * 512, int]]     # 0 none, 1 ro, 2 rw, over blocks 20..22
  var seed = 12345'u32
  proc rnd(): uint32 =
    seed = seed * 1664525'u32 + 1013904223'u32
    seed shr 8
  for step in 0 ..< 3000:
    let who = int(rnd() mod 2)
    let first = int(rnd() mod 1536)
    let n = 1 + int(rnd() mod uint32(min(700, 1536 - first)))
    let mode = int(rnd() mod 3)
    assert spaceSetPages(sp(who), blockVa(20) + uint64(first) * 4096, uint64(n) * 4096, mode != 0, mode == 2)
    for i in first ..< first + n: model[who][i] = mode
    if step mod 50 == 0:
      for w in 0 ..< 2:
        for i in 0 ..< 1536:
          let a = acc(w, blockVa(20) + uint64(i) * 4096)
          assert a.present
          assert a.user == (model[w][i] != 0) and (model[w][i] == 0 or a.writable == (model[w][i] == 2)),
            "space " & $w & " page " & $i & " disagrees with the model"
  echo "PASS: ownership is page-granular: neighbouring pages of one 2 MB block belong to different spaces; whole blocks stay huge; split/merge keep the model"

proc testSync() =
  initMaster()
  assert spaceBuild(sp(0), rp()) and spaceBuild(sp(1), rp())
  assert spaceGrantWindow(sp(0), regionVa(2), RegionSize, true)
  assert spaceSetBlock(sp(0), blockVa(1), user = true, writable = true)
  # the kernel maps a new DMA window, a device, and a whole new top-level entry after the spaces exist
  master.pd[200] = (200'u64 * HugePage) or Flags or PteHuge
  master.pd[3] = master.pd[3] or (1'u64 shl 4)
  master.pdpt[2] = 0x123000'u64 or Flags
  master.pml4[7] = 0x456000'u64 or Flags
  assert not acc(0, 200'u64 * HugePage).present, "not visible before the sync"
  spaceSyncKernel(sp(0), rp())
  assert acc(0, 200'u64 * HugePage).present and not acc(0, 200'u64 * HugePage).user
  assert spaces[0].pd[3] == master.pd[3] and spaces[0].pdpt[2] == master.pdpt[2] and spaces[0].pml4[7] == master.pml4[7]
  # the task's own windows and links survived
  assert acc(0, regionVa(2)).user and acc(0, blockVa(1)).user and acc(0, blockVa(1)).writable
  assert (spaces[0].pml4[0] and AddrMask) == cast[uint64](addr spaces[0].pdpt)
  assert (spaces[0].pdpt[0] and AddrMask) == cast[uint64](addr spaces[0].pd)
  # a sync of an untouched space changes nothing it owns
  spaceSyncKernel(sp(1), rp())
  assert not acc(1, regionVa(2)).user
  echo "PASS: kernel mappings added later reach every space; a task's own windows survive the sync"

when isMainModule:
  testBuild()
  testIsolation()
  testSync()
  testPages()
  echo "All address space tests passed."
