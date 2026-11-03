# SPDX-License-Identifier: GPL-2.0
## Host tests for mm/user_window — fake identity page tables, no hardware.

import ../mm/user_window

proc newTable(): ptr PageTable =
  ## Page-aligned zeroed table (entries store its address like a phys frame).
  let raw = cast[uint64](alloc0(sizeof(PageTable) + 4096))
  cast[ptr PageTable]((raw + 4095) and not 4095'u64)

proc bootLikeMap(): ptr PageTable =
  ## PML4[0] → PDPT[0] → PD with 32 × 2 MB huge pages (flags 0x83, no User).
  let pml4 = newTable(); let pdpt = newTable(); let pd = newTable()
  pml4[0] = cast[uint64](pdpt) or 0x03
  pdpt[0] = cast[uint64](pd) or 0x03
  for i in 0 ..< 32: pd[i] = uint64(i) * HugePage or 0x83
  pml4

proc pdOf(pml4: ptr PageTable): ptr PageTable =
  cast[ptr PageTable](cast[ptr PageTable](pml4[0] and not 0xFFF'u64)[0] and not 0xFFF'u64)

block grant_exactly_the_window:
  let pml4 = bootLikeMap()
  let base = 0x2000000'u64                      # region slot 0 (32 MB)
  assert setUserWindow(pml4, base, 4 * 1024 * 1024, true)
  let pd = pdOf(pml4)
  for i in 0 ..< 32:
    let inWindow = i in 16 .. 17
    assert ((pd[i] and PteUser) != 0) == inWindow, "only the app's 2 huge pages are User"
  assert (pml4[0] and PteUser) != 0, "parent PML4 entry allows user walk"
  echo "PASS: grant_exactly_the_window"

block revoke_restores_supervisor:
  let pml4 = bootLikeMap()
  let base = 0x2000000'u64
  assert setUserWindow(pml4, base, 4 * 1024 * 1024, true)
  assert setUserWindow(pml4, base, 4 * 1024 * 1024, false)
  let pd = pdOf(pml4)
  for i in 0 ..< 32:
    assert (pd[i] and PteUser) == 0, "no User bit left after revoke"
    assert pd[i] == (uint64(i) * HugePage or 0x83), "other bits untouched"
  echo "PASS: revoke_restores_supervisor"

block unmapped_window_fails:
  let pml4 = bootLikeMap()
  # 64 MB+ is beyond the 32-entry boot map: refuse rather than invent a mapping.
  assert not setUserWindow(pml4, 0x4000000'u64, 2 * 1024 * 1024, true)
  echo "PASS: unmapped_window_fails"

echo "All user_window tests passed."

block map_identity_beyond_the_boot_map:
  let pml4 = bootLikeMap()
  let pd = pdOf(pml4)
  let before = pd[5]
  assert mapIdentityHuge(pml4, 0'u64, 112 * HugePage)      # through the arena (224 MB)
  assert pd[5] == before, "existing boot entries untouched"
  for i in 32 ..< 112:
    assert pd[i] == (uint64(i) * HugePage or 0x83), "new entries: identity, supervisor, RW, huge"
  assert pd[112] == 0, "nothing past the requested range"
  echo "PASS: map_identity_beyond_the_boot_map"

block block_rights_follow_access:
  let pml4 = bootLikeMap()
  let pd = pdOf(pml4)
  let va = 20 * HugePage
  assert setBlockRights(pml4, va, user = true, writable = true)
  assert (pd[20] and (PteUser or PteWritable)) == (PteUser or PteWritable)
  assert setBlockRights(pml4, va, user = true, writable = false)   # sealed: read-only
  assert (pd[20] and PteUser) != 0 and (pd[20] and PteWritable) == 0
  assert setBlockRights(pml4, va, user = false, writable = false)  # no user access
  assert pd[20] == (20'u64 * HugePage or 0x83), "back to the kernel-only boot flags"
  assert not setBlockRights(pml4, va, user = false, writable = false), "unchanged: no flush needed"
  echo "PASS: block_rights_follow_access"
