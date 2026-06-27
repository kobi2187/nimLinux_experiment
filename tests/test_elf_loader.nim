# SPDX-License-Identifier: GPL-2.0
## Tests for ELF loader bounds checking — host-side, no hardware.
{.define: noKernelHardware.}

import ../runtime/elf_loader

# Minimal valid ELF64 PIE header with one PT_LOAD segment that fits.
# We won't actually load bytes — just test the header validation paths.

proc testBoundsCheckOkSegment() =
  ## Segment with vaddr just under the limit: must NOT return elfLoadOob.
  ## We use a crafted ELF with p_filesz=0, p_memsz=0 to avoid any memcpy/zeroing.
  ## The bounds check fires on (p_vaddr + p_memsz > regionSize) — with both 0, it passes.
  var buf = newSeq[byte](256)
  buf[0] = 0x7F; buf[1] = ord('E'); buf[2] = ord('L'); buf[3] = ord('F')
  buf[4] = 2; buf[5] = 1; buf[6] = 1
  buf[16] = 3; buf[18] = 62; buf[20] = 1
  buf[32] = 64; buf[54] = 56; buf[56] = 1
  buf[64] = 1  # PT_LOAD, p_vaddr=0, p_filesz=0, p_memsz=0
  # all size fields remain 0 — no copy, no zero, just the check
  let res = elfLoadPie(cast[ptr byte](addr buf[0]), buf.len, 0, nil, 0, 4*1024*1024)
  assert res.err != elfLoadOob, "zero-size segment must not return elfLoadOob"
  echo "PASS: elf_bounds_ok_segment"

proc testBoundsCheckFail() =
  ## Segment vaddr=0, memsz=5MB — exceeds 4MB region. Must return elfLoadOob.
  ## With p_filesz=0 the file-size check passes; only memsz check fires.
  ## Elf64Phdr layout at buf[64]:
  ##   +0  p_type   (4B) = 1 (PT_LOAD)
  ##   +4  p_flags  (4B) = 0
  ##   +8  p_offset (8B) = 0  → filesz check: 0+0 <= buflen, OK
  ##   +16 p_vaddr  (8B) = 0
  ##   +24 p_paddr  (8B) = 0
  ##   +32 p_filesz (8B) = 0  → no memcpy
  ##   +40 p_memsz  (8B) = 0x500000 (5MB) → 0+5MB > 4MB → elfLoadOob
  var buf = newSeq[byte](256)
  buf[0] = 0x7F; buf[1] = ord('E'); buf[2] = ord('L'); buf[3] = ord('F')
  buf[4] = 2; buf[5] = 1; buf[6] = 1
  buf[16] = 3; buf[18] = 62; buf[20] = 1
  buf[32] = 64; buf[54] = 56; buf[56] = 1
  buf[64] = 1  # PT_LOAD
  # p_memsz at buf[64+40=104]: 0x500000 = 5MB (LE bytes)
  buf[104] = 0x00; buf[105] = 0x00; buf[106] = 0x50  # 0x00500000
  let res = elfLoadPie(cast[ptr byte](addr buf[0]), buf.len, 0, nil, 0, 4*1024*1024)
  assert res.err == elfLoadOob, "5MB segment in 4MB region must return elfLoadOob, got: " & $res.err
  echo "PASS: elf_bounds_overflow"

proc makeRela(offset, symIdx: uint64; relocType: uint32; addend: int64): Elf64Rela =
  Elf64Rela(r_offset: offset,
            r_info:   (symIdx shl 32) or uint64(relocType),
            r_addend: addend)

proc testGlobDatRelocType() =
  assert R_X86_64_GLOB_DAT == 6'u32
  echo "PASS: R_X86_64_GLOB_DAT == 6"

proc testJumpSlotRelocType() =
  assert R_X86_64_JUMP_SLOT == 7'u32
  echo "PASS: R_X86_64_JUMP_SLOT == 7"

proc testR64RelocType() =
  assert R_X86_64_64 == 1'u32
  echo "PASS: R_X86_64_64 == 1"

proc testRelocInfoExtract() =
  ## Verify symIdx and relocType encoding in r_info.
  let rela = makeRela(0x1000'u64, 5'u64, 6'u32, 0)
  let relocType = uint32(rela.r_info and 0xFFFF_FFFF'u64)
  let symIdx    = rela.r_info shr 32
  assert relocType == 6'u32, "reloc type from r_info"
  assert symIdx    == 5'u64, "sym index from r_info"
  echo "PASS: r_info encodes symIdx and relocType correctly"

proc testPtInterpConst() =
  assert PT_INTERP == 3'u32
  echo "PASS: PT_INTERP == 3"

when isMainModule:
  testBoundsCheckOkSegment()
  testBoundsCheckFail()
  testGlobDatRelocType()
  testJumpSlotRelocType()
  testR64RelocType()
  testRelocInfoExtract()
  testPtInterpConst()
  echo "All ELF loader tests passed."
