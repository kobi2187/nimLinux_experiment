# SPDX-License-Identifier: GPL-2.0
## x86_64 CPU Primitives - LAYER 0
##
## Low-level CPU operations: control registers, MSRs, I/O ports, etc.

import ../../core/types

# ═══════════════════════════════════════════════════════════════════════════
# Control Registers
# ═══════════════════════════════════════════════════════════════════════════

proc readCr0*(): uint64 {.inline.} =
  ## Read CR0 register
  {.emit: """asm volatile("mov %%cr0, %0" : "=r" (`result`));""".}

proc writeCr0*(value: uint64) {.inline.} =
  ## Write CR0 register
  {.emit: ["asm volatile(\"mov %0, %%cr0\" :: \"r\" (", value, ") : \"memory\");"].}

proc readCr2*(): uint64 {.inline.} =
  ## Read CR2 register (page fault linear address)
  {.emit: """asm volatile("mov %%cr2, %0" : "=r" (`result`));""".}

proc readCr3*(): uint64 {.inline.} =
  ## Read CR3 register (page table base)
  {.emit: """asm volatile("mov %%cr3, %0" : "=r" (`result`));""".}

proc writeCr3*(value: uint64) {.inline.} =
  ## Write CR3 register (flush TLB)
  {.emit: ["asm volatile(\"mov %0, %%cr3\" :: \"r\" (", value, ") : \"memory\");"].}

proc readCr4*(): uint64 {.inline.} =
  ## Read CR4 register
  {.emit: """asm volatile("mov %%cr4, %0" : "=r" (`result`));""".}

proc writeCr4*(value: uint64) {.inline.} =
  ## Write CR4 register
  {.emit: ["asm volatile(\"mov %0, %%cr4\" :: \"r\" (", value, ") : \"memory\");"].}

# CR0 bits
const
  CR0_PE* = 1'u64 shl 0      ## Protection Enable
  CR0_MP* = 1'u64 shl 1      ## Monitor Coprocessor
  CR0_EM* = 1'u64 shl 2      ## Emulation
  CR0_TS* = 1'u64 shl 3      ## Task Switched
  CR0_ET* = 1'u64 shl 4      ## Extension Type
  CR0_NE* = 1'u64 shl 5      ## Numeric Error
  CR0_WP* = 1'u64 shl 16     ## Write Protect
  CR0_AM* = 1'u64 shl 18     ## Alignment Mask
  CR0_NW* = 1'u64 shl 29     ## Not Write-through
  CR0_CD* = 1'u64 shl 30     ## Cache Disable
  CR0_PG* = 1'u64 shl 31     ## Paging

# CR4 bits
const
  CR4_VME* = 1'u64 shl 0     ## Virtual-8086 Mode Extensions
  CR4_PVI* = 1'u64 shl 1     ## Protected-Mode Virtual Interrupts
  CR4_TSD* = 1'u64 shl 2     ## Time Stamp Disable
  CR4_DE* = 1'u64 shl 3      ## Debugging Extensions
  CR4_PSE* = 1'u64 shl 4     ## Page Size Extensions
  CR4_PAE* = 1'u64 shl 5     ## Physical Address Extension
  CR4_MCE* = 1'u64 shl 6     ## Machine-Check Enable
  CR4_PGE* = 1'u64 shl 7     ## Page Global Enable
  CR4_PCE* = 1'u64 shl 8     ## Performance-Monitoring Counter Enable
  CR4_OSFXSR* = 1'u64 shl 9  ## OS Support for FXSAVE/FXRSTOR
  CR4_OSXMMEXCPT* = 1'u64 shl 10  ## OS Support for Unmasked SIMD FP Exceptions
  CR4_UMIP* = 1'u64 shl 11   ## User-Mode Instruction Prevention
  CR4_FSGSBASE* = 1'u64 shl 16  ## Enable RDFSBASE/WRFSBASE
  CR4_PCIDE* = 1'u64 shl 17  ## PCID Enable
  CR4_OSXSAVE* = 1'u64 shl 18  ## XSAVE and Extended States Enable
  CR4_SMEP* = 1'u64 shl 20   ## Supervisor Mode Execution Prevention
  CR4_SMAP* = 1'u64 shl 21   ## Supervisor Mode Access Prevention

# ═══════════════════════════════════════════════════════════════════════════
# Model Specific Registers (MSRs)
# ═══════════════════════════════════════════════════════════════════════════

proc readMsr*(msr: uint32): uint64 {.inline.} =
  ## Read MSR
  var lo, hi: uint32
  {.emit: ["asm volatile(\"rdmsr\" : \"=a\" (", lo, "), \"=d\" (", hi, ") : \"c\" (", msr, "));"].}
  result = (uint64(hi) shl 32) or uint64(lo)

proc writeMsr*(msr: uint32, value: uint64) {.inline.} =
  ## Write MSR
  let lo = uint32(value and 0xFFFFFFFF)
  let hi = uint32(value shr 32)
  {.emit: ["asm volatile(\"wrmsr\" :: \"a\" (", lo, "), \"d\" (", hi, "), \"c\" (", msr, ") : \"memory\");"].}

# Common MSR addresses
const
  MSR_APIC_BASE* = 0x1B'u32
  MSR_EFER* = 0xC0000080'u32
  MSR_STAR* = 0xC0000081'u32
  MSR_LSTAR* = 0xC0000082'u32
  MSR_CSTAR* = 0xC0000083'u32
  MSR_SFMASK* = 0xC0000084'u32
  MSR_FS_BASE* = 0xC0000100'u32
  MSR_GS_BASE* = 0xC0000101'u32
  MSR_KERNEL_GS_BASE* = 0xC0000102'u32
  MSR_TSC_AUX* = 0xC0000103'u32

# EFER bits
const
  EFER_SCE* = 1'u64 shl 0    ## System Call Enable
  EFER_LME* = 1'u64 shl 8    ## Long Mode Enable
  EFER_LMA* = 1'u64 shl 10   ## Long Mode Active
  EFER_NXE* = 1'u64 shl 11   ## No-Execute Enable

# ═══════════════════════════════════════════════════════════════════════════
# GS/FS Base (fast path when FSGSBASE is enabled)
# ═══════════════════════════════════════════════════════════════════════════

proc readGsBase*(): uint64 {.inline.} =
  ## Read GS base (requires FSGSBASE)
  {.emit: """asm volatile("rdgsbase %0" : "=r" (`result`));""".}

proc writeGsBase*(base: uint64) {.inline.} =
  ## Write GS base (requires FSGSBASE)
  {.emit: ["asm volatile(\"wrgsbase %0\" :: \"r\" (", base, ") : \"memory\");"].}

proc readFsBase*(): uint64 {.inline.} =
  ## Read FS base (requires FSGSBASE)
  {.emit: """asm volatile("rdfsbase %0" : "=r" (`result`));""".}

proc writeFsBase*(base: uint64) {.inline.} =
  ## Write FS base (requires FSGSBASE)
  {.emit: ["asm volatile(\"wrfsbase %0\" :: \"r\" (", base, ") : \"memory\");"].}

proc swapGs*() {.inline.} =
  ## Swap GS base with kernel GS base
  {.emit: """asm volatile("swapgs" ::: "memory");""".}

# ═══════════════════════════════════════════════════════════════════════════
# I/O Ports
# ═══════════════════════════════════════════════════════════════════════════

proc inb*(port: uint16): uint8 {.inline.} =
  ## Read byte from I/O port
  {.emit: ["asm volatile(\"inb %1, %0\" : \"=a\" (", result, ") : \"Nd\" (", port, "));"].}

proc outb*(port: uint16, value: uint8) {.inline.} =
  ## Write byte to I/O port
  {.emit: ["asm volatile(\"outb %0, %1\" :: \"a\" (", value, "), \"Nd\" (", port, "));"].}

proc inw*(port: uint16): uint16 {.inline.} =
  ## Read word from I/O port
  {.emit: ["asm volatile(\"inw %1, %0\" : \"=a\" (", result, ") : \"Nd\" (", port, "));"].}

proc outw*(port: uint16, value: uint16) {.inline.} =
  ## Write word to I/O port
  {.emit: ["asm volatile(\"outw %0, %1\" :: \"a\" (", value, "), \"Nd\" (", port, "));"].}

proc inl*(port: uint16): uint32 {.inline.} =
  ## Read dword from I/O port
  {.emit: ["asm volatile(\"inl %1, %0\" : \"=a\" (", result, ") : \"Nd\" (", port, "));"].}

proc outl*(port: uint16, value: uint32) {.inline.} =
  ## Write dword to I/O port
  {.emit: ["asm volatile(\"outl %0, %1\" :: \"a\" (", value, "), \"Nd\" (", port, "));"].}

proc ioWait*() {.inline.} =
  ## I/O wait (delay for slow devices)
  outb(0x80, 0)

# ═══════════════════════════════════════════════════════════════════════════
# Interrupts
# ═══════════════════════════════════════════════════════════════════════════

proc cli*() {.inline.} =
  ## Disable interrupts
  {.emit: """asm volatile("cli" ::: "memory");""".}

proc sti*() {.inline.} =
  ## Enable interrupts
  {.emit: """asm volatile("sti" ::: "memory");""".}

proc hlt*() {.inline.} =
  ## Halt CPU until next interrupt
  {.emit: """asm volatile("hlt");""".}

proc interruptsEnabled*(): bool {.inline.} =
  ## Check if interrupts are enabled
  var flags: uint64
  {.emit: ["asm volatile(\"pushfq; pop %0\" : \"=r\" (", flags, "));"].}
  result = (flags and 0x200) != 0

proc disableInterrupts*(): uint64 {.inline.} =
  ## Disable interrupts, return previous state
  var flags: uint64
  {.emit: ["asm volatile(\"pushfq; pop %0; cli\" : \"=r\" (", flags, ") :: \"memory\");"].}
  result = flags

proc restoreInterrupts*(flags: uint64) {.inline.} =
  ## Restore interrupt state
  if (flags and 0x200) != 0:
    sti()

# ═══════════════════════════════════════════════════════════════════════════
# TLB Operations
# ═══════════════════════════════════════════════════════════════════════════

proc invalidatePage*(address: VirtAddr) {.inline.} =
  ## Invalidate single TLB entry
  {.emit: ["asm volatile(\"invlpg (%0)\" :: \"r\" (", uint64(address), ") : \"memory\");"].}

proc flushTlb*() {.inline.} =
  ## Flush entire TLB by reloading CR3
  writeCr3(readCr3())

# ═══════════════════════════════════════════════════════════════════════════
# CPUID
# ═══════════════════════════════════════════════════════════════════════════

type
  CpuidResult* = object
    eax*, ebx*, ecx*, edx*: uint32

proc cpuid*(leaf: uint32, subleaf: uint32 = 0): CpuidResult {.inline.} =
  ## Execute CPUID instruction
  {.emit: ["""asm volatile("cpuid"
    : "=a" (""", result.eax, """), "=b" (""", result.ebx, """), "=c" (""", result.ecx, """), "=d" (""", result.edx, """)
    : "a" (""", leaf, """), "c" (""", subleaf, """));"""].}

# ═══════════════════════════════════════════════════════════════════════════
# Timestamp Counter
# ═══════════════════════════════════════════════════════════════════════════

proc rdtsc*(): uint64 {.inline.} =
  ## Read timestamp counter
  var lo, hi: uint32
  {.emit: ["asm volatile(\"rdtsc\" : \"=a\" (", lo, "), \"=d\" (", hi, "));"].}
  result = (uint64(hi) shl 32) or uint64(lo)

proc rdtscp*(): tuple[tsc: uint64, aux: uint32] {.inline.} =
  ## Read timestamp counter (serializing) with processor ID
  var lo, hi, aux: uint32
  {.emit: ["asm volatile(\"rdtscp\" : \"=a\" (", lo, "), \"=d\" (", hi, "), \"=c\" (", aux, "));"].}
  result.tsc = (uint64(hi) shl 32) or uint64(lo)
  result.aux = aux

# ═══════════════════════════════════════════════════════════════════════════
# Special Instructions
# ═══════════════════════════════════════════════════════════════════════════

proc lidt*(base: pointer, limit: uint16) {.inline.} =
  ## Load IDT register
  var idtr {.noinit.}: array[10, uint8]
  let baseAddr = cast[uint64](base)
  cast[ptr uint16](addr idtr[0])[] = limit
  cast[ptr uint64](addr idtr[2])[] = baseAddr
  {.emit: ["asm volatile(\"lidt %0\" :: \"m\" (", idtr, ") : \"memory\");"].}

proc lgdt*(base: pointer, limit: uint16) {.inline.} =
  ## Load GDT register
  var gdtr {.noinit.}: array[10, uint8]
  let baseAddr = cast[uint64](base)
  cast[ptr uint16](addr gdtr[0])[] = limit
  cast[ptr uint64](addr gdtr[2])[] = baseAddr
  {.emit: ["asm volatile(\"lgdt %0\" :: \"m\" (", gdtr, ") : \"memory\");"].}

proc ltr*(selector: uint16) {.inline.} =
  ## Load task register
  {.emit: ["asm volatile(\"ltr %0\" :: \"r\" (", selector, "));"].}

proc wbinvd*() {.inline.} =
  ## Write back and invalidate cache
  {.emit: """asm volatile("wbinvd" ::: "memory");""".}
