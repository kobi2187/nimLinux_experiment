/* SPDX-License-Identifier: GPL-2.0
 * Kernel Entry Point - x86_64 Assembly
 *
 * This is the first code that executes when the kernel boots.
 * Multiboot2-compliant bootloader (e.g., GRUB) loads this and jumps here.
 *
 * Responsibilities:
 * 1. Multiboot2 header (tells bootloader what we need)
 * 2. 32-bit protected mode setup
 * 3. Long mode (64-bit) transition
 * 4. Call Nim early_init function
 * 5. Call Nim kernel_main function
 *
 * Philosophy: Minimal assembly, delegate to Nim ASAP
 */

.set ALIGN,    1<<0             /* align loaded modules on page boundaries */
.set MEMINFO,  1<<1             /* provide memory map */
.set FLAGS,    ALIGN | MEMINFO  /* this is the Multiboot 'flag' field */
.set MAGIC,    0x1BADB002       /* 'magic number' lets bootloader find the header */
.set CHECKSUM, -(MAGIC + FLAGS) /* checksum of above, to prove we are multiboot */

/* Multiboot2 Header for GRUB
 * Located at beginning of kernel image (will be adjusted by linker)
 */

.section .multiboot_header
.align 4
.long MAGIC
.long FLAGS
.long CHECKSUM
.long 0  /* header_addr (0 = not used) */
.long 0  /* load_addr */
.long 0  /* load_end_addr */
.long 0  /* bss_end_addr */
.long 0  /* entry_addr (0 = use start of text segment) */

/* Bootloader may provide this; we'll read from stack/registers */
.long 0  /* framebuffer type */
.long 0  /* width */
.long 0  /* height */
.long 0  /* depth */

/* End tag */
.short 0
.short 0
.long 8

/* =========================================================================
 * 32-bit Protected Mode Entry Point
 * =========================================================================
 *
 * At this point:
 * - Bootloader has put us in 32-bit protected mode
 * - GDT is set up (but basic, not our final one)
 * - Interrupts are disabled
 * - Paging is off
 * - EAX = Multiboot magic number (0x1BADB002)
 * - EBX = Address of boot info structure
 */

.section .text
.code32
.globl _start
_start:
    /* ===== MULTIBOOT2 Protocol: Save boot info ===== */

    mov %eax, %edi              /* EAX has Multiboot magic -> save as arg1 */
    mov %ebx, %esi              /* EBX has boot info ptr -> save as arg2 */

    /* ===== Setup stack ===== */

    mov $stack_top, %esp        /* Set up stack pointer */
    mov %esp, %ebp              /* Frame pointer = stack pointer */

    /* ===== Check CPU features ===== */

    /* Check for PAE (Physical Address Extension) */
    mov $1, %eax
    cpuid
    test $(1 << 6), %edx        /* PAE bit */
    jz cpu_no_pae

    /* Check for long mode support */
    mov $0x80000001, %eax
    cpuid
    test $(1 << 29), %edx       /* Long mode bit */
    jz cpu_no_longmode

    /* ===== Setup Page Tables for Long Mode ===== */

    /* Create minimal page tables for boot
     * PML4 entry -> PDPT entry -> PD entry -> PT entry
     * We need to identity-map first 4MB and map kernel space
     */

    /* Clear page tables (zero out 4KB aligned buffer) */
    mov $page_tables, %edi
    xor %eax, %eax
    mov $1024, %ecx             /* 1024 * 4 bytes = 4KB */
    rep stosd

    /* Build PML4 (first 512 entries = identity map, rest = kernel) */
    mov $page_tables, %eax      /* PML4 address */
    or $0x03, %eax              /* Present + Writable */

    /* PML4[0] -> PDPT (identity map low addresses) */
    mov %eax, page_tables(%eax)

    /* PML4[256] -> PDPT (kernel high addresses) */
    add $(512 * 8), %eax
    mov %eax, page_tables + (256 * 8)

    /* ===== Setup Long Mode GDT ===== */

    /* GDT will be loaded by Nim code, but we need a minimal one to start */
    lgdt gdt_descriptor

    /* ===== Enable PAE ===== */

    mov %cr4, %eax
    or $(1 << 5), %eax          /* Set PAE bit */
    mov %eax, %cr4

    /* ===== Enable Long Mode ===== */

    mov $0xC0000080, %ecx       /* EFER MSR */
    rdmsr
    or $(1 << 8), %eax          /* Set LME (Long Mode Enable) */
    wrmsr

    /* ===== Enable Paging ===== */

    mov $page_tables, %eax
    mov %eax, %cr3              /* Load PML4 */

    mov %cr0, %eax
    or $(1 << 31), %eax         /* Set PG bit */
    mov %eax, %cr0

    /* ===== Jump to 64-bit code ===== */

    ljmp $0x08, $long_mode_start  /* Jump to 64-bit code segment */

cpu_no_pae:
    hlt
    jmp cpu_no_pae

cpu_no_longmode:
    hlt
    jmp cpu_no_longmode

/* =========================================================================
 * 64-bit Long Mode - Now we can call Nim code!
 * =========================================================================
 */

.section .text
.code64
long_mode_start:
    /* ===== Setup 64-bit segments ===== */

    mov $0x10, %ax              /* Data segment */
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    xor %ax, %ax
    mov %ax, %fs
    mov %ax, %gs

    /* ===== Clear CPU state ===== */

    xor %rax, %rax
    xor %rbx, %rbx
    xor %rcx, %rcx
    xor %rdx, %rdx
    xor %rsi, %rsi
    xor %rbp, %rbp
    xor %r8, %r8
    xor %r9, %r9
    xor %r10, %r10
    xor %r11, %r11
    xor %r12, %r12
    xor %r13, %r13
    xor %r14, %r14
    xor %r15, %r15

    /* ===== Prepare Nim ABI args ===== */

    /* System V AMD64 ABI:
     * First 6 integer/pointer arguments in: rdi, rsi, rdx, rcx, r8, r9
     * Return value in: rax
     */

    mov %edi, %edi              /* Boot magic (was in EAX) -> RDI */
    mov %esi, %esi              /* Boot info ptr (was in EBX) -> RSI */

    /* ===== Call Nim kernel_main ===== */

    call kernel_main

    /* ===== Halt if kernel_main returns (it shouldn't) ===== */

    cli                         /* Disable interrupts */
hang:
    hlt
    jmp hang

/* =========================================================================
 * Minimal GDT for Long Mode Boot
 * =========================================================================
 *
 * In 64-bit mode, most GDT fields are ignored.
 * We just need valid code and data descriptors.
 */

.align 8
gdt_table:
    /* Entry 0: Null descriptor (required) */
    .quad 0x0000000000000000

    /* Entry 1: Code descriptor (64-bit)
     * Type: Code | DPL: 0 | Present: 1 | Long: 1
     */
    .quad 0x00209A0000000000    /* L=1, DPL=0, Code, Present */

    /* Entry 2: Data descriptor (64-bit)
     * Type: Data | DPL: 0 | Present: 1
     */
    .quad 0x0000920000000000    /* DPL=0, Data, Present */

gdt_descriptor:
    .word (gdt_descriptor - gdt_table - 1)  /* Size - 1 */
    .quad gdt_table                         /* Base address */

/* =========================================================================
 * Stack for Kernel Boot
 * =========================================================================
 */

.section .bss
.align 16
stack:
    .skip 16384                 /* 16KB stack */
stack_top:

/* =========================================================================
 * Minimal Page Tables for Boot
 * =========================================================================
 */

.section .bss
.align 4096
page_tables:
    .skip 4096                  /* One 4KB page for page tables (we'll use more later) */
