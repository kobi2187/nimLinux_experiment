# SPDX-License-Identifier: GPL-2.0
## ELF Loader — pure Nim
##
## Loads 64-bit ELF executables (ET_EXEC) and PIE binaries (ET_DYN).
## For PIE: allocates a region, copies segments, applies R_X86_64_RELATIVE
## relocations, patches weak ABI symbols with kernel function addresses,
## then calls appMain().
##
## ELF spec: https://refspecs.linuxfoundation.org/elf/elf.pdf
## x86_64 ABI: https://refspecs.linuxfoundation.org/elf/x86_64-abi-0.99.pdf

import ../core/log

# ── ELF64 structs ─────────────────────────────────────────────────────────────

const
  ElfMagic     = [0x7F'u8, ord('E'), ord('L'), ord('F')]
  ElfClass64   = 2'u8
  ElfDataLE    = 1'u8
  ElfTypeExec  = 2'u16   ## Non-PIE executable
  ElfTypeDyn   = 3'u16   ## PIE executable (ET_DYN)
  ElfMachX64   = 0x3E'u16
  PT_LOAD      = 1'u32
  PT_DYNAMIC   = 2'u32
  DT_RELA      = 7'u64   ## Address of RELA table
  DT_RELASZ    = 8'u64   ## Total size of RELA table in bytes
  DT_RELAENT   = 9'u64   ## Size of one RELA entry (should be 24)
  R_X86_64_RELATIVE = 8'u32
  STT_FUNC     = 2'u8
  STB_WEAK     = 2'u8
  SHT_SYMTAB   = 2'u32
  SHT_STRTAB   = 3'u32
  SHT_RELA     = 4'u32

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

  Elf64Sym {.packed.} = object
    st_name:  uint32
    st_info:  uint8    ## (binding << 4) | type
    st_other: uint8
    st_shndx: uint16
    st_value: uint64
    st_size:  uint64

  Elf64Rela {.packed.} = object
    r_offset: uint64   ## Address of the slot to patch
    r_info:   uint64   ## Symbol index (high 32) | reloc type (low 32)
    r_addend: int64

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
    elfNotExec        ## Not ET_EXEC or ET_DYN
    elfBadPhdr
    elfLoadOob
    elfNoRegion       ## allocRegion returned nil
    elfBadReloc       ## Unknown relocation type

  ElfLoadResult* = object
    err*:      ElfError
    entry*:    uint64   ## Absolute entry point after relocation
    loadBase*: uint64   ## Base address where the binary was placed
    loadEnd*:  uint64   ## End of mapped region
    appMain*:  uint64   ## Address of appMain symbol (0 if not found)

# ── Validation ────────────────────────────────────────────────────────────────

proc elfCheck*(data: ptr byte; size: int): ElfError =
  if size < int(sizeof(Elf64Ehdr)): return elfTooSmall
  let h = cast[ptr Elf64Ehdr](data)
  if h.e_ident[0] != ElfMagic[0] or h.e_ident[1] != ElfMagic[1] or
     h.e_ident[2] != ElfMagic[2] or h.e_ident[3] != ElfMagic[3]:
    return elfBadMagic
  if h.e_ident[4] != ElfClass64:  return elfBad64
  if h.e_ident[5] != ElfDataLE:   return elfBadEndian
  if h.e_machine  != ElfMachX64:  return elfBadMachine
  if h.e_type != ElfTypeExec and h.e_type != ElfTypeDyn:
    return elfNotExec
  elfOk

# ── Helpers ───────────────────────────────────────────────────────────────────

proc cstrEq(a: ptr UncheckedArray[byte]; b: cstring): bool =
  var i = 0
  while b[i] != '\0':
    if a[i] != uint8(b[i]): return false
    inc i
  a[i] == 0

# ── PIE loader ────────────────────────────────────────────────────────────────

type
  AbiPatch* = object
    ## One ABI symbol to patch: the weak stub gets overwritten with
    ## `movabs rax, <nr>; syscall` so the app issues a syscall with
    ## the syscall number baked in.
    name*: cstring
    nr*:   uint64   ## NimixSyscall ordinal

proc elfLoadPie*(data: ptr byte; size: int;
                 regionBase: uint64;
                 patches: ptr UncheckedArray[AbiPatch];
                 patchCount: int): ElfLoadResult =
  ## Load a PIE ELF (ET_DYN) into `regionBase`.
  ## Applies R_X86_64_RELATIVE relocations from .rela.dyn.
  ## Patches weak ABI symbols by overwriting their stub bodies with
  ## a 64-bit absolute jmp (14 bytes: movabs rax, <fn>; jmp rax).
  ## Fills result.appMain with the absolute address of appMain.

  result.err = elfCheck(data, size)
  if result.err != elfOk: return

  let fileBase = cast[uint64](data)
  let hdr      = cast[ptr Elf64Ehdr](data)
  let bias     = regionBase  ## relocation bias: add to all relative addrs

  # ── 1. Map PT_LOAD segments ────────────────────────────────────────────────
  result.loadBase = high(uint64)
  result.loadEnd  = 0

  for i in 0'u16 ..< hdr.e_phnum:
    let phOff = hdr.e_phoff + uint64(i) * uint64(hdr.e_phentsize)
    if phOff + uint64(sizeof(Elf64Phdr)) > uint64(size):
      result.err = elfBadPhdr; return
    let ph = cast[ptr Elf64Phdr](fileBase + phOff)
    if ph.p_type != PT_LOAD: continue
    if ph.p_offset + ph.p_filesz > uint64(size):
      result.err = elfBadPhdr; return

    let dst = cast[ptr UncheckedArray[byte]](bias + ph.p_vaddr)
    let src = cast[ptr UncheckedArray[byte]](fileBase + ph.p_offset)
    for j in 0'u64 ..< ph.p_filesz:
      dst[j] = src[j]
    for j in ph.p_filesz ..< ph.p_memsz:
      dst[j] = 0'u8

    if ph.p_vaddr < result.loadBase: result.loadBase = ph.p_vaddr
    let segEnd = ph.p_vaddr + ph.p_memsz
    if segEnd > result.loadEnd: result.loadEnd = segEnd
    klogInt(llInfo, "ELF PIE: mapped segment at bias+0x", int64(ph.p_vaddr))

  result.loadBase += bias
  result.loadEnd  += bias
  result.entry     = bias + hdr.e_entry

  # ── 2. Apply R_X86_64_RELATIVE from .rela.dyn (via PT_DYNAMIC) ────────────
  var relaAddr  = 0'u64
  var relaSz    = 0'u64
  var relaEnt   = 24'u64  ## default RELA entry size

  for i in 0'u16 ..< hdr.e_phnum:
    let phOff = hdr.e_phoff + uint64(i) * uint64(hdr.e_phentsize)
    let ph = cast[ptr Elf64Phdr](fileBase + phOff)
    if ph.p_type != PT_DYNAMIC: continue
    let dynCount = ph.p_filesz div uint64(sizeof(Elf64Dyn))
    let dynBase  = bias + ph.p_vaddr
    for d in 0'u64 ..< dynCount:
      let entry = cast[ptr Elf64Dyn](dynBase + d * uint64(sizeof(Elf64Dyn)))
      case entry.d_tag
      of DT_RELA:    relaAddr = bias + entry.d_val
      of DT_RELASZ:  relaSz   = entry.d_val
      of DT_RELAENT: relaEnt  = entry.d_val
      else: discard
    break

  if relaAddr != 0 and relaSz > 0:
    let count = relaSz div relaEnt
    for i in 0'u64 ..< count:
      let rela = cast[ptr Elf64Rela](relaAddr + i * relaEnt)
      let relocType = uint32(rela.r_info and 0xFFFF_FFFF'u64)
      if relocType == R_X86_64_RELATIVE:
        # *slot = bias + addend
        let slot = cast[ptr uint64](rela.r_offset + bias)
        slot[] = bias + uint64(rela.r_addend)
      elif relocType == 0:
        discard  # R_X86_64_NONE — skip
      else:
        klogInt(llWarn, "ELF PIE: unknown reloc type ", int64(relocType))
    klogInt(llInfo, "ELF PIE: applied relocations, count=", int64(count))

  # ── 3. Patch weak ABI stubs via .symtab ───────────────────────────────────
  # Walk section headers to find .symtab and its associated .strtab.
  if hdr.e_shoff == 0 or hdr.e_shnum == 0: discard  # no sections, skip
  else:
    let shBase = fileBase + hdr.e_shoff
    var symtabIdx = -1
    var strtabIdx = -1

    for i in 0 ..< int(hdr.e_shnum):
      let sh = cast[ptr Elf64Shdr](shBase + uint64(i) * uint64(hdr.e_shentsize))
      if sh.sh_type == SHT_SYMTAB:
        symtabIdx = i
        strtabIdx = int(sh.sh_link)
        break

    if symtabIdx >= 0 and strtabIdx >= 0:
      let symSh = cast[ptr Elf64Shdr](shBase + uint64(symtabIdx) * uint64(hdr.e_shentsize))
      let strSh = cast[ptr Elf64Shdr](shBase + uint64(strtabIdx) * uint64(hdr.e_shentsize))
      let symBase = fileBase + symSh.sh_offset
      let strBase = cast[ptr UncheckedArray[byte]](fileBase + strSh.sh_offset)
      let symCount = symSh.sh_size div uint64(sizeof(Elf64Sym))

      for i in 0'u64 ..< symCount:
        let sym = cast[ptr Elf64Sym](symBase + i * uint64(sizeof(Elf64Sym)))
        if sym.st_value == 0: continue
        let binding = sym.st_info shr 4
        if binding != STB_WEAK: continue  # only patch weak stubs

        let namePtr = cast[ptr UncheckedArray[byte]](addr strBase[sym.st_name])

        # Check if this symbol matches any requested ABI patch
        for p in 0 ..< patchCount:
          if cstrEq(namePtr, patches[p].name):
            # Write: movabs rax, <nr>   (10 bytes: 48 B8 <8-byte-imm>)
            #        syscall            (2 bytes:  0F 05)
            # The syscall number is baked in; the kernel's syscall_entry
            # dispatches through syscallTable[nr] to the right ABI proc.
            let stubAddr = bias + sym.st_value
            let stub = cast[ptr UncheckedArray[byte]](stubAddr)
            stub[0] = 0x48; stub[1] = 0xB8  # REX.W mov rax, imm64
            let nr = patches[p].nr
            stub[2] = uint8(nr and 0xFF)
            stub[3] = uint8((nr shr 8)  and 0xFF)
            stub[4] = uint8((nr shr 16) and 0xFF)
            stub[5] = uint8((nr shr 24) and 0xFF)
            stub[6] = uint8((nr shr 32) and 0xFF)
            stub[7] = uint8((nr shr 40) and 0xFF)
            stub[8] = uint8((nr shr 48) and 0xFF)
            stub[9] = uint8((nr shr 56) and 0xFF)
            stub[10] = 0x0F; stub[11] = 0x05  # syscall
            klog(llInfo, "ELF PIE: patched ABI stub → syscall")
            break

        # Also capture appMain address
        if cstrEq(namePtr, "appMain"):
          result.appMain = bias + sym.st_value

      # appMain may be a global (non-weak) symbol — scan all
      for i in 0'u64 ..< symCount:
        let sym = cast[ptr Elf64Sym](symBase + i * uint64(sizeof(Elf64Sym)))
        if sym.st_value == 0: continue
        let namePtr = cast[ptr UncheckedArray[byte]](addr strBase[sym.st_name])
        if cstrEq(namePtr, "appMain"):
          result.appMain = bias + sym.st_value
          break

  klogInt(llInfo, "ELF PIE: appMain at 0x", int64(result.appMain))
  result.err = elfOk

# ── Non-PIE loader (kept for ET_EXEC binaries) ────────────────────────────────

proc elfLoad*(data: ptr byte; size: int): ElfLoadResult =
  result.err = elfCheck(data, size)
  if result.err != elfOk:
    klogInt(llError, "ELF check failed: ", int64(ord(result.err)))
    return
  let hdr  = cast[ptr Elf64Ehdr](data)
  let base = cast[uint64](data)
  result.entry    = hdr.e_entry
  result.loadBase = high(uint64)
  result.loadEnd  = 0
  for i in 0'u16 ..< hdr.e_phnum:
    let phOff = hdr.e_phoff + uint64(i) * uint64(hdr.e_phentsize)
    if phOff + uint64(sizeof(Elf64Phdr)) > uint64(size):
      result.err = elfBadPhdr; return
    let ph = cast[ptr Elf64Phdr](base + phOff)
    if ph.p_type != PT_LOAD: continue
    if ph.p_offset + ph.p_filesz > uint64(size):
      result.err = elfBadPhdr; return
    let dst = cast[ptr UncheckedArray[byte]](ph.p_vaddr)
    let src = cast[ptr UncheckedArray[byte]](base + ph.p_offset)
    for j in 0'u64 ..< ph.p_filesz: dst[j] = src[j]
    for j in ph.p_filesz ..< ph.p_memsz: dst[j] = 0'u8
    if ph.p_vaddr < result.loadBase: result.loadBase = ph.p_vaddr
    let segEnd = ph.p_vaddr + ph.p_memsz
    if segEnd > result.loadEnd: result.loadEnd = segEnd
    klogInt(llInfo, "ELF: loaded segment at 0x", int64(ph.p_vaddr))
  klogInt(llInfo, "ELF: entry point 0x", int64(hdr.e_entry))
  result.err = elfOk
