# SPDX-License-Identifier: GPL-2.0
## ELF Loader — pure Nim
##
## Parses a 64-bit ELF binary and loads its PT_LOAD segments into memory.
## This is enough to run statically-linked ELF executables as kernel tasks
## (ring 0 for now; ring 3 requires page table setup, coming later).
##
## ELF spec: https://refspecs.linuxfoundation.org/elf/elf.pdf
## x86_64 ABI: https://refspecs.linuxfoundation.org/elf/x86_64-abi-0.99.pdf

import ../core/log
import ../core/types

# ── ELF64 Header ──────────────────────────────────────────────────────────────
# Reference: ELF-64 Object File Format v1.5, §3

const
  ElfMagic    = [0x7F'u8, ord('E'), ord('L'), ord('F')]
  ElfClass64  = 2'u8    ## 64-bit ELF
  ElfDataLE   = 1'u8    ## Little-endian
  ElfTypeExec = 2'u16   ## Executable file
  ElfMachX64  = 0x3E'u16 ## AMD x86-64
  PT_LOAD     = 1'u32   ## Loadable segment
  PF_X        = 1'u32   ## Segment execute permission
  PF_W        = 2'u32   ## Segment write permission
  PF_R        = 4'u32   ## Segment read permission

type
  Elf64Ehdr {.packed.} = object
    e_ident:     array[16, uint8]   ## Magic, class, data, version, OS/ABI...
    e_type:      uint16              ## Object file type
    e_machine:   uint16              ## Target ISA
    e_version:   uint32              ## ELF version (must be 1)
    e_entry:     uint64              ## Entry point virtual address
    e_phoff:     uint64              ## Program header table offset
    e_shoff:     uint64              ## Section header table offset (unused)
    e_flags:     uint32
    e_ehsize:    uint16              ## ELF header size (64 bytes)
    e_phentsize: uint16              ## Program header entry size (56 bytes)
    e_phnum:     uint16              ## Number of program header entries
    e_shentsize: uint16
    e_shnum:     uint16
    e_shstrndx:  uint16

  Elf64Phdr {.packed.} = object
    p_type:   uint32   ## Segment type (PT_LOAD etc.)
    p_flags:  uint32   ## Segment permissions (PF_R|PF_W|PF_X)
    p_offset: uint64   ## Offset in file
    p_vaddr:  uint64   ## Virtual address to load at
    p_paddr:  uint64   ## Physical address (unused for userspace)
    p_filesz: uint64   ## Bytes in file image
    p_memsz:  uint64   ## Bytes in memory (≥ p_filesz; extra = zeroed BSS)
    p_align:  uint64   ## Alignment

# ── Validation ────────────────────────────────────────────────────────────────

type
  ElfError* = enum
    elfOk
    elfTooSmall      ## Buffer smaller than ELF header
    elfBadMagic      ## Not an ELF file
    elfBad64         ## Not a 64-bit ELF
    elfBadEndian     ## Not little-endian
    elfBadMachine    ## Not x86-64
    elfNotExec       ## Not an executable
    elfBadPhdr       ## Program header outside buffer
    elfLoadOob       ## Segment load address out of bounds for our allocator

proc elfCheck*(data: ptr byte, size: int): ElfError =
  if size < int(sizeof(Elf64Ehdr)):     return elfTooSmall
  let hdr = cast[ptr Elf64Ehdr](data)
  if hdr.e_ident[0] != ElfMagic[0] or
     hdr.e_ident[1] != ElfMagic[1] or
     hdr.e_ident[2] != ElfMagic[2] or
     hdr.e_ident[3] != ElfMagic[3]:    return elfBadMagic
  if hdr.e_ident[4] != ElfClass64:     return elfBad64
  if hdr.e_ident[5] != ElfDataLE:      return elfBadEndian
  if hdr.e_machine != ElfMachX64:      return elfBadMachine
  if hdr.e_type    != ElfTypeExec:     return elfNotExec
  elfOk

# ── Loading ───────────────────────────────────────────────────────────────────

type
  ElfLoadResult* = object
    err*:      ElfError
    entry*:    uint64   ## Entry point virtual address
    loadBase*: uint64   ## Lowest virtual address loaded (useful for PIE)
    loadEnd*:  uint64   ## Highest virtual address + 1

proc elfLoad*(data: ptr byte, size: int): ElfLoadResult =
  ## Load ELF segments into memory.
  ## For now: direct load (segments go to their p_vaddr addresses).
  ## Works for statically linked non-PIE ELFs like our server binaries.
  result.err = elfCheck(data, size)
  if result.err != elfOk:
    klogInt(llError, "ELF check failed: ", int64(ord(result.err)))
    return

  let hdr  = cast[ptr Elf64Ehdr](data)
  let base = cast[uint64](data)

  result.entry   = hdr.e_entry
  result.loadBase = high(uint64)
  result.loadEnd  = 0

  # Walk program headers
  for i in 0'u16 ..< hdr.e_phnum:
    let phdrOff = hdr.e_phoff + uint64(i) * uint64(hdr.e_phentsize)
    if phdrOff + uint64(sizeof(Elf64Phdr)) > uint64(size):
      result.err = elfBadPhdr
      return

    let ph = cast[ptr Elf64Phdr](base + phdrOff)
    if ph.p_type != PT_LOAD:
      continue  # skip non-loadable segments (NOTE, DYNAMIC, etc.)

    # Validate file slice
    if ph.p_offset + ph.p_filesz > uint64(size):
      result.err = elfBadPhdr
      return

    # Copy file image to virtual address
    let dst = cast[ptr UncheckedArray[byte]](ph.p_vaddr)
    let src = cast[ptr UncheckedArray[byte]](base + ph.p_offset)
    for j in 0'u64 ..< ph.p_filesz:
      dst[j] = src[j]

    # Zero BSS (memory size > file size)
    for j in ph.p_filesz ..< ph.p_memsz:
      dst[j] = 0'u8

    # Track load range
    if ph.p_vaddr < result.loadBase:
      result.loadBase = ph.p_vaddr
    let segEnd = ph.p_vaddr + ph.p_memsz
    if segEnd > result.loadEnd:
      result.loadEnd = segEnd

    klogInt(llInfo, "ELF: loaded segment at 0x", int64(ph.p_vaddr))

  klogInt(llInfo, "ELF: entry point 0x", int64(hdr.e_entry))
  result.err = elfOk
