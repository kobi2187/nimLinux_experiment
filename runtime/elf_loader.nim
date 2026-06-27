# SPDX-License-Identifier: GPL-2.0
## ELF Loader — pure Nim
##
## Loads 64-bit ELF executables (ET_EXEC) and PIE binaries (ET_DYN).
## For PIE: allocates a region, copies segments, applies R_X86_64_RELATIVE
## relocations, patches weak ABI symbols with kernel function addresses,
## then calls appMain().

import ../core/log

# ── ELF64 structs ─────────────────────────────────────────────────────────────

const
  ElfMagic          = [0x7F'u8, ord('E'), ord('L'), ord('F')]
  ElfClass64        = 2'u8
  ElfDataLE         = 1'u8
  ElfTypeExec*      = 2'u16
  ElfTypeDyn*       = 3'u16
  ElfMachX64        = 0x3E'u16
  PT_LOAD           = 1'u32
  PT_DYNAMIC        = 2'u32
  PT_INTERP*        = 3'u32
  DT_RELA           = 7'u64
  DT_RELASZ         = 8'u64
  DT_RELAENT        = 9'u64
  DT_SYMTAB         = 6'u64
  DT_SYMENT         = 11'u64
  R_X86_64_64*        = 1'u32
  R_X86_64_RELATIVE   = 8'u32
  R_X86_64_GLOB_DAT*  = 6'u32
  R_X86_64_JUMP_SLOT* = 7'u32
  STB_WEAK          = 2'u8
  SHT_SYMTAB        = 2'u32

type
  Elf64Ehdr {.packed.} = object
    e_ident:     array[16, uint8]
    e_type:      uint16
    e_machine:   uint16
    e_version:   uint32
    e_entry:     uint64
    e_phoff:     uint64
    e_shoff:     uint64
    e_flags:     uint32
    e_ehsize:    uint16
    e_phentsize: uint16
    e_phnum:     uint16
    e_shentsize: uint16
    e_shnum:     uint16
    e_shstrndx:  uint16

  Elf64Phdr {.packed.} = object
    p_type:   uint32
    p_flags:  uint32
    p_offset: uint64
    p_vaddr:  uint64
    p_paddr:  uint64
    p_filesz: uint64
    p_memsz:  uint64
    p_align:  uint64

  Elf64Shdr {.packed.} = object
    sh_name:      uint32
    sh_type:      uint32
    sh_flags:     uint64
    sh_addr:      uint64
    sh_offset:    uint64
    sh_size:      uint64
    sh_link:      uint32
    sh_info:      uint32
    sh_addralign: uint64
    sh_entsize:   uint64

  Elf64Sym* {.packed.} = object
    st_name:  uint32
    st_info:  uint8
    st_other: uint8
    st_shndx: uint16
    st_value: uint64
    st_size:  uint64

  Elf64Rela* {.packed.} = object
    r_offset*: uint64
    r_info*:   uint64
    r_addend*: int64

  Elf64Dyn {.packed.} = object
    d_tag: uint64
    d_val: uint64

# ── Error / result types ──────────────────────────────────────────────────────

type
  ElfError* = enum
    elfOk
    elfTooSmall
    elfBadMagic
    elfBad64
    elfBadEndian
    elfBadMachine
    elfNotExec
    elfBadPhdr
    elfLoadOob
    elfNoRegion
    elfBadReloc

  ElfLoadResult* = object
    err*:      ElfError
    entry*:    uint64
    loadBase*: uint64
    loadEnd*:  uint64
    appMain*:  uint64

  AbiPatch* = object
    name*: cstring
    nr*:   uint64

# ── Type aliases for readability ──────────────────────────────────────────────

type
  Bytes = ptr UncheckedArray[uint8]
  Ehdr  = ptr Elf64Ehdr
  Phdr  = ptr Elf64Phdr
  Shdr  = ptr Elf64Shdr
  Sym   = ptr Elf64Sym
  Rela  = ptr Elf64Rela
  Dyn   = ptr Elf64Dyn

# ── Pointer arithmetic helpers ────────────────────────────────────────────────

proc atOffset(base: uint64; off: uint64): uint64 {.inline.} = base + off
proc asBytes(p: uint64): Bytes {.inline.} = cast[Bytes](p)
proc asEhdr(p: uint64): Ehdr  {.inline.} = cast[Ehdr](p)
proc asPhdr(p: uint64): Phdr  {.inline.} = cast[Phdr](p)
proc asShdr(p: uint64): Shdr  {.inline.} = cast[Shdr](p)
proc asSym(p: uint64):  Sym   {.inline.} = cast[Sym](p)
proc asRela(p: uint64): Rela  {.inline.} = cast[Rela](p)
proc asDyn(p: uint64):  Dyn   {.inline.} = cast[Dyn](p)
proc asU64(p: uint64):  ptr uint64 {.inline.} = cast[ptr uint64](p)

# ── Validation ────────────────────────────────────────────────────────────────

proc elfCheck*(data: ptr byte; size: int): ElfError =
  if size < int(sizeof(Elf64Ehdr)): return elfTooSmall
  let h = cast[Ehdr](data)
  if h.e_ident[0] != ElfMagic[0] or h.e_ident[1] != ElfMagic[1] or
     h.e_ident[2] != ElfMagic[2] or h.e_ident[3] != ElfMagic[3]:
    return elfBadMagic
  if h.e_ident[4] != ElfClass64: return elfBad64
  if h.e_ident[5] != ElfDataLE:  return elfBadEndian
  if h.e_machine  != ElfMachX64: return elfBadMachine
  if h.e_type != ElfTypeExec and h.e_type != ElfTypeDyn: return elfNotExec
  elfOk

# ── String helpers ────────────────────────────────────────────────────────────

proc cstrEq(a: Bytes; b: cstring): bool =
  var i = 0
  while b[i] != '\0':
    if a[i] != uint8(b[i]): return false
    inc i
  a[i] == 0

# ── Segment mapping ───────────────────────────────────────────────────────────

proc copySegment(dst, src: Bytes; filesz, memsz: uint64) =
  for j in 0'u64 ..< filesz: dst[j] = src[j]
  for j in filesz ..< memsz:  dst[j] = 0'u8

proc mapLoadSegment(r: var ElfLoadResult; fileBase, bias: uint64;
                    ph: Phdr; fileSize: int): bool =
  if ph.p_offset + ph.p_filesz > uint64(fileSize):
    r.err = elfBadPhdr; return false
  if ph.p_vaddr + ph.p_memsz > uint64(4 * 1024 * 1024):
    klogInt(llError, "ELF PIE: segment overflow at vaddr=0x", int64(ph.p_vaddr))
    r.err = elfLoadOob; return false
  copySegment(asBytes(bias + ph.p_vaddr),
              asBytes(atOffset(fileBase, ph.p_offset)),
              ph.p_filesz, ph.p_memsz)
  if ph.p_vaddr < r.loadBase: r.loadBase = ph.p_vaddr
  let segEnd = ph.p_vaddr + ph.p_memsz
  if segEnd > r.loadEnd: r.loadEnd = segEnd
  klogInt(llInfo, "ELF PIE: mapped segment at bias+0x", int64(ph.p_vaddr))
  true

proc mapAllLoadSegments(r: var ElfLoadResult; fileBase, bias: uint64;
                        h: Ehdr; fileSize: int): bool =
  r.loadBase = high(uint64)
  r.loadEnd  = 0
  for i in 0'u16 ..< h.e_phnum:
    let phOff = h.e_phoff + uint64(i) * uint64(h.e_phentsize)
    if phOff + uint64(sizeof(Elf64Phdr)) > uint64(fileSize):
      r.err = elfBadPhdr; return false
    let ph = asPhdr(atOffset(fileBase, phOff))
    if ph.p_type == PT_INTERP: klog(llInfo, "ELF PIE: PT_INTERP stripped"); continue
    if ph.p_type != PT_LOAD: continue
    if not mapLoadSegment(r, fileBase, bias, ph, fileSize): return false
  r.loadBase += bias
  r.loadEnd  += bias
  true

# ── RELA relocations ──────────────────────────────────────────────────────────

type DynInfo = object
  relaAddr, relaSz, relaEnt: uint64
  symtabAddr, syment:        uint64

proc parseDynamic(bias: uint64; ph: Phdr; di: var DynInfo) =
  let dynCount = ph.p_filesz div uint64(sizeof(Elf64Dyn))
  let dynBase  = bias + ph.p_vaddr
  for d in 0'u64 ..< dynCount:
    let entry = asDyn(dynBase + d * uint64(sizeof(Elf64Dyn)))
    case entry.d_tag
    of DT_RELA:    di.relaAddr   = bias + entry.d_val
    of DT_RELASZ:  di.relaSz     = entry.d_val
    of DT_RELAENT: di.relaEnt    = entry.d_val
    of DT_SYMTAB:  di.symtabAddr = bias + entry.d_val
    of DT_SYMENT:  di.syment     = entry.d_val
    else: discard

proc findDynamic(fileBase, bias: uint64; h: Ehdr; di: var DynInfo) =
  for i in 0'u16 ..< h.e_phnum:
    let ph = asPhdr(atOffset(fileBase, h.e_phoff + uint64(i) * uint64(h.e_phentsize)))
    if ph.p_type == PT_DYNAMIC:
      parseDynamic(bias, ph, di)
      break

proc symValue(di: DynInfo; symIdx, bias: uint64): uint64 =
  ## Look up st_value for symbol index in .dynsym, add bias.
  if di.symtabAddr == 0 or symIdx == 0: return 0
  bias + asSym(di.symtabAddr + symIdx * di.syment).st_value

proc applyOneReloc(rela: Rela; di: DynInfo; bias: uint64) =
  let relocType = uint32(rela.r_info and 0xFFFF_FFFF'u64)
  let symIdx    = rela.r_info shr 32
  let slot      = asU64(rela.r_offset + bias)
  case relocType
  of R_X86_64_RELATIVE:  slot[] = bias + uint64(rela.r_addend)
  of R_X86_64_64:        slot[] = symValue(di, symIdx, bias) + uint64(rela.r_addend)
  of R_X86_64_GLOB_DAT:  slot[] = symValue(di, symIdx, bias) + uint64(rela.r_addend)
  of R_X86_64_JUMP_SLOT: slot[] = symValue(di, symIdx, 0'u64)  # no bias for PLT
  of 0'u32: discard  # R_X86_64_NONE
  else: klogInt(llWarn, "ELF PIE: unknown reloc type ", int64(relocType))

proc applyAllRelocs(di: DynInfo; bias: uint64) =
  let count = di.relaSz div di.relaEnt
  for i in 0'u64 ..< count:
    applyOneReloc(asRela(di.relaAddr + i * di.relaEnt), di, bias)
  klogInt(llInfo, "ELF PIE: applied relocations, count=", int64(count))

proc applyRelocations(fileBase, bias: uint64; h: Ehdr) =
  var di = DynInfo(relaEnt: 24'u64, syment: 24'u64)
  findDynamic(fileBase, bias, h, di)
  if di.relaAddr != 0 and di.relaSz > 0:
    applyAllRelocs(di, bias)

# ── Symbol table — ABI patching ───────────────────────────────────────────────

proc emitSyscallTrampoline(stubAddr, nr: uint64) =
  let stub = asBytes(stubAddr)
  stub[0] = 0x48; stub[1] = 0xB8        # movabs rax, imm64
  for k in 0..<8: stub[2+k] = uint8((nr shr (k*8)) and 0xFF)
  stub[10] = 0x0F; stub[11] = 0x05      # syscall

proc patchSymbol(sym: Sym; namePtr: Bytes; bias: uint64;
                 patches: ptr UncheckedArray[AbiPatch]; patchCount: int) =
  if (sym.st_info shr 4) != STB_WEAK: return
  for p in 0 ..< patchCount:
    if cstrEq(namePtr, patches[p].name):
      emitSyscallTrampoline(bias + sym.st_value, patches[p].nr)
      klog(llInfo, "ELF PIE: patched ABI stub → syscall")
      break

proc findAppMain(sym: Sym; namePtr: Bytes; bias: uint64): uint64 =
  if cstrEq(namePtr, "appMain"): bias + sym.st_value else: 0

proc walkSymtab(fileBase, bias: uint64; symSh, strSh: Shdr;
                patches: ptr UncheckedArray[AbiPatch]; patchCount: int;
                appMainAddr: var uint64) =
  let symBase  = atOffset(fileBase, symSh.sh_offset)
  let strBase  = asBytes(atOffset(fileBase, strSh.sh_offset))
  let symCount = symSh.sh_size div uint64(sizeof(Elf64Sym))
  for i in 0'u64 ..< symCount:
    let sym = asSym(symBase + i * uint64(sizeof(Elf64Sym)))
    if sym.st_value == 0: continue
    let namePtr = asBytes(cast[uint64](addr strBase[sym.st_name]))
    patchSymbol(sym, namePtr, bias, patches, patchCount)
    let m = findAppMain(sym, namePtr, bias)
    if m != 0: appMainAddr = m

proc findSymtab(fileBase: uint64; h: Ehdr): tuple[sym, str: Shdr] =
  let shBase = atOffset(fileBase, h.e_shoff)
  for i in 0 ..< int(h.e_shnum):
    let sh = asShdr(shBase + uint64(i) * uint64(h.e_shentsize))
    if sh.sh_type == SHT_SYMTAB:
      return (sh, asShdr(shBase + uint64(sh.sh_link) * uint64(h.e_shentsize)))
  (nil, nil)

proc patchAbiSymbols(fileBase, bias: uint64; h: Ehdr;
                     patches: ptr UncheckedArray[AbiPatch]; patchCount: int;
                     appMainAddr: var uint64) =
  if h.e_shoff == 0 or h.e_shnum == 0: return
  let (symSh, strSh) = findSymtab(fileBase, h)
  if symSh == nil: return
  walkSymtab(fileBase, bias, symSh, strSh, patches, patchCount, appMainAddr)

# ── PIE loader ────────────────────────────────────────────────────────────────

proc elfLoadPie*(data: ptr byte; size: int;
                 regionBase: uint64;
                 patches: ptr UncheckedArray[AbiPatch];
                 patchCount: int;
                 regionSize: uint64 = 4 * 1024 * 1024): ElfLoadResult =
  result.err = elfCheck(data, size)
  if result.err != elfOk: return
  let fileBase = cast[uint64](data)
  let h        = asEhdr(fileBase)
  let bias     = regionBase
  if not mapAllLoadSegments(result, fileBase, bias, h, size): return
  result.entry = bias + h.e_entry
  applyRelocations(fileBase, bias, h)
  patchAbiSymbols(fileBase, bias, h, patches, patchCount, result.appMain)
  klogInt(llInfo, "ELF PIE: appMain at 0x", int64(result.appMain))
  result.err = elfOk

# ── Non-PIE loader ────────────────────────────────────────────────────────────

proc elfLoad*(data: ptr byte; size: int): ElfLoadResult =
  result.err = elfCheck(data, size)
  if result.err != elfOk:
    klogInt(llError, "ELF check failed: ", int64(ord(result.err))); return
  let h    = cast[Ehdr](data)
  let base = cast[uint64](data)
  result.entry    = h.e_entry
  result.loadBase = high(uint64)
  result.loadEnd  = 0
  for i in 0'u16 ..< h.e_phnum:
    let phOff = h.e_phoff + uint64(i) * uint64(h.e_phentsize)
    if phOff + uint64(sizeof(Elf64Phdr)) > uint64(size):
      result.err = elfBadPhdr; return
    let ph = asPhdr(atOffset(base, phOff))
    if ph.p_type != PT_LOAD: continue
    if ph.p_offset + ph.p_filesz > uint64(size):
      result.err = elfBadPhdr; return
    copySegment(asBytes(ph.p_vaddr), asBytes(atOffset(base, ph.p_offset)),
                ph.p_filesz, ph.p_memsz)
    if ph.p_vaddr < result.loadBase: result.loadBase = ph.p_vaddr
    let segEnd = ph.p_vaddr + ph.p_memsz
    if segEnd > result.loadEnd: result.loadEnd = segEnd
    klogInt(llInfo, "ELF: loaded segment at 0x", int64(ph.p_vaddr))
  klogInt(llInfo, "ELF: entry point 0x", int64(h.e_entry))
  result.err = elfOk
