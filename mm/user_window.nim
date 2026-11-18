# SPDX-License-Identifier: GPL-2.0
## User window — grant/revoke ring-3 access to one app's region.
##
## The boot stub identity-maps low memory with 2 MB huge pages and no User bit,
## so ring 3 could not fetch its own code (#PF err 0x15). An app gets User
## access to exactly its own 4 MB region at spawn and loses it at exit; kernel
## memory stays supervisor-only. Interim step: all apps still share one address
## space, so per-app CR3 is the real isolation boundary (DECISIONS 2026-10-25).
##
## Pure core: walks tables reachable by identity (entry address == pointer),
## which holds for the boot map and for host-test tables alike.

const
  PtePresent* = 1'u64
  PteUser*    = 1'u64 shl 2
  PteHuge*    = 1'u64 shl 7
  HugePage*   = 2'u64 * 1024 * 1024
  AddrMask*   = 0x000F_FFFF_FFFF_F000'u64

type PageTable* = array[512, uint64]

proc tableAt(entry: uint64): ptr PageTable {.inline.} =
  cast[ptr PageTable](entry and AddrMask)

proc setUserWindow*(pml4: ptr PageTable; base, len: uint64; user: bool): bool =
  ## Set/clear the User bit on the 2 MB huge-page PD entries covering
  ## [base, base+len) (both 2 MB aligned). Parents get User when granting —
  ## harmless, leaves decide. False if any chunk is unmapped or not a huge page.
  assert (base mod HugePage) == 0 and (len mod HugePage) == 0, "2 MB aligned"
  var va = base
  while va < base + len:
    let l4 = addr pml4[(va shr 39) and 511]
    if (l4[] and PtePresent) == 0: return false
    let l3 = addr tableAt(l4[])[(va shr 30) and 511]
    if (l3[] and PtePresent) == 0: return false
    let pd = addr tableAt(l3[])[(va shr 21) and 511]
    if (pd[] and PtePresent) == 0 or (pd[] and PteHuge) == 0: return false
    if user:
      l4[] = l4[] or PteUser
      l3[] = l3[] or PteUser
      pd[]  = pd[] or PteUser
    else:
      pd[]  = pd[] and not PteUser
    va += HugePage
  true

const PteWritable* = 1'u64 shl 1

proc mapIdentityHuge*(pml4: ptr PageTable; base, len: uint64): bool =
  ## Identity-map [base, base+len) with 2 MB supervisor pages wherever no
  ## mapping exists yet (the boot stub maps only the first 64 MB). Needs the
  ## PML4/PDPT entries of that 1 GB range to exist (the boot map has them).
  assert (base mod HugePage) == 0 and (len mod HugePage) == 0, "2 MB aligned"
  var va = base
  while va < base + len:
    let l4 = pml4[(va shr 39) and 511]
    if (l4 and PtePresent) == 0: return false
    let l3 = tableAt(l4)[(va shr 30) and 511]
    if (l3 and PtePresent) == 0 or (l3 and PteHuge) != 0: return false
    let pd = addr tableAt(l3)[(va shr 21) and 511]
    if (pd[] and PtePresent) == 0:
      pd[] = va or PtePresent or PteWritable or PteHuge
    va += HugePage
  true

proc setBlockRights*(pml4: ptr PageTable; va: uint64; user, writable: bool): bool =
  ## Buffer enforcement (Stage A): User/RW of one 2 MB huge page. True if the
  ## entry changed (the caller then flushes it from the TLB).
  let l4 = pml4[(va shr 39) and 511]
  if (l4 and PtePresent) == 0: return false
  let l3 = tableAt(l4)[(va shr 30) and 511]
  if (l3 and PtePresent) == 0: return false
  let pd = addr tableAt(l3)[(va shr 21) and 511]
  if (pd[] and PteHuge) == 0: return false
  var e = pd[] and not (PteUser or PteWritable)
  if user: e = e or PteUser
  if writable or not user: e = e or PteWritable   # kernel keeps write when no user has it
  if e == pd[]: return false
  pd[] = e
  true

import region_allocator

when defined(kernelFull):
  import ../arch/x86_64/cpu_primitives

  proc invlpg(va: uint64) {.inline.} =
    {.emit: ["asm volatile(\"invlpg (%0)\" :: \"r\" (", va, ") : \"memory\");"].}

  proc appRegionUserAccess*(slot: RegionHandle; user: bool): bool =
    ## Grant (spawn) or revoke (exit) ring-3 access to an app's region.
    let base = regionBase(slot)
    result = setUserWindow(cast[ptr PageTable](readCr3() and AddrMask),
                           base, RegionSize, user)
    var va = base
    while va < base + RegionSize:
      invlpg(va)
      va += HugePage
else:
  proc appRegionUserAccess*(slot: RegionHandle; user: bool): bool =
    ## Host builds have no page tables to change.
    true
