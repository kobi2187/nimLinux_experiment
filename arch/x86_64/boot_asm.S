/* SPDX-License-Identifier: GPL-2.0 */
/* NimixOS Boot Stub — x86_64
 *
 * Responsibilities:
 *   1. Declare a Multiboot2 header so GRUB recognizes us
 *   2. Transition from 32-bit protected mode → 64-bit long mode
 *   3. Call NimMain() (ARC runtime init) then kernelMain(magic, infoPtr)
 *
 * Page tables: identity-map the first 64 MB via 2 MB huge pages.
 * This covers the kernel image (~88 KB text/rodata/data + 16 MB BSS heap).
 */

/* ═══════════════════════════════════════════════════════════════════════════
 * Multiboot2 Header
 * ─────────────────
 * Must be 8-byte aligned, within the first 32 KB of the image.
 * Spec: https://www.gnu.org/software/grub/manual/multiboot2/multiboot.html
 * ═══════════════════════════════════════════════════════════════════════════ */

.section .text.boot, "ax"
.align 8

multiboot2_header:
    .long 0xE85250D6                       /* magic              */
    .long 0                                 /* architecture 0 = i386 */
    .long multiboot2_header_end - multiboot2_header /* header length */
    .long -(0xE85250D6 + 0 + (multiboot2_header_end - multiboot2_header)) /* checksum */

    /* End tag (required) */
    .word 0                                 /* type: end          */
    .word 0                                 /* flags              */
    .long 8                                 /* size               */
multiboot2_header_end:

/* ═══════════════════════════════════════════════════════════════════════════
 * 32-bit Entry
 * ────────────
 * GRUB jumps here in 32-bit protected mode with:
 *   EAX = 0x36d76289 (Multiboot2 magic)
 *   EBX = physical address of Multiboot2 info structure
 * ═══════════════════════════════════════════════════════════════════════════ */

.code32
.global _start
_start:
    /* Save bootloader-provided values before they get clobbered */
    mov %eax, (magic_reg)
    mov %ebx, (info_ptr)

    /* ── Check CPUID availability ──────────────────────────────────── */
    /*   The ID flag (bit 21) of EFLAGS indicates CPUID support.       */
    pushfl
    pushfl
    xorl $(1<<21), (%esp)        /* toggle ID */
    popfl
    pushfl
    popl %ecx
    xorl (%esp), %ecx            /* ECX = changed bits */
    popfl
    test %ecx, %ecx
    jz  .Lhalt                   /* CPUID not available — halt */

    /* ── Check for long mode support ───────────────────────────────── */
    /*   First verify extended function 0x80000001 exists.             */
    mov $0x80000000, %eax
    cpuid
    cmp $0x80000001, %eax
    jb  .Lhalt                   /* no extended functions — halt */

    /*   Then check LM (long mode) bit 29 in EDX.                      */
    mov $0x80000001, %eax
    cpuid
    test $(1<<29), %edx
    jz  .Lhalt                   /* no long mode — halt */

    /* ── Set up identity-mapped page tables ────────────────────────── */

    /*   PML4 entry 0 → PDPT (Present | Writable)                      */
    lea (pdpt), %eax
    or  $(0x03), %eax
    mov %eax, (pml4)

    /*   PDPT entry 0 → PD   (Present | Writable)                      */
    lea (pd), %eax
    or  $(0x03), %eax
    mov %eax, (pdpt)

    /*   PD entries 0..31: 2 MB huge pages (Present | Writable | Huge) */
    lea (pd), %edi               /* EDI = base of PD */
    xor %ecx, %ecx               /* ECX = entry index */
    mov $0x83, %eax              /* EAX = physical base 0 + flags      */

.Lfill_pd:
    mov %eax, (%edi, %ecx, 8)   /* pd[ecx] = entry */
    add $(2*1024*1024), %eax     /* advance physical by 2 MB */
    inc %ecx
    cmp $32, %ecx                /* 32 entries × 2 MB = 64 MB */
    jne .Lfill_pd

    /* ── Enable PAE (Physical Address Extension) ───────────────────── */
    mov %cr4, %eax
    or  $(1<<5), %eax            /* CR4.PAE = 1 */
    mov %eax, %cr4

    /* ── Load PML4 base into CR3 ───────────────────────────────────── */
    lea (pml4), %eax
    mov %eax, %cr3

    /* ── Enable Long Mode via the EFER MSR ─────────────────────────── */
    /*   0xC0000080 = IA32_EFER, bit 8 = LME (Long Mode Enable)        */
    mov $0xC0000080, %ecx
    rdmsr
    or  $(1<<8), %eax
    wrmsr

    /* ── Enable Paging (CR0.PG) ────────────────────────────────────── */
    /*   Also set CR0.PE (Protection Enable) — it's already set by
     *   GRUB, but we set it again for robustness.                      */
    mov %cr0, %eax
    or  $(1<<31), %eax           /* CR0.PG = 1 */
    mov %eax, %cr0

    /* ── Load a minimal 64-bit GDT ─────────────────────────────────── */
    lgdt (gdt_ptr)

    /* ── Far jump to 64-bit code segment ───────────────────────────── */
    /*   Selector 0x08 = index 1, RPL 0, GDT (64-bit code segment).    */
    ljmp $0x08, $.L64

/* ═══════════════════════════════════════════════════════════════════════════
 * 64-bit Long Mode
 * ────────────────
 * Now running in 64-bit long mode.  Set up segments, stack, and call Nim.
 * ═══════════════════════════════════════════════════════════════════════════ */

.code64
.L64:
    /* Reload segment registers with 64-bit data segment (selector 0x10) */
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs
    mov %ax, %ss

    /* Set up a 64-bit stack from BSS region.
     *
     * IMPORTANT: ABI requires RSP mod 16 == 0 BEFORE a call instruction.
     * The call pushes 8 bytes (return address), making RSP mod 16 == 8
     * at function entry. This is the required ABI state.
     *
     * Therefore: just align to 16 — no extra subtraction.  Every
     * call-site must maintain RSP mod 16 == 0 before the call, which
     * means that between two calls we must have mod 16 == 0. */
    lea (stack_top), %rsp
    and $~15, %rsp

    /* DEBUG: print messages via C stub before NimMain to verify
     * that both debug_serial_str calls work when nothing interferes. */
    lea (dbg_msg_entry), %rdi
    call debug_serial_str
    lea (dbg_msg_nim), %rdi
    call debug_serial_str

    /* Initialize Nim's ARC runtime (sets up StandaloneHeapSize pool) */
    call NimMain

    /* DEBUG: test if debug_serial_str STILL works after NimMain */
    lea (dbg_msg_nim), %rdi
    call debug_serial_str

    /* Load magic and info_ptr, then call kernelMain */
    mov (magic_reg), %edi
    mov (info_ptr), %esi
    call kernelMain

    /* kernelMain should never return; but if it does, halt forever */
    cli
.Lhlt:
    hlt
    jmp .Lhlt

.Lhalt:
    /* CPU doesn't support long mode — halt */
    cli
.Lhalt_loop:
    hlt
    jmp .Lhalt_loop

/* ═══════════════════════════════════════════════════════════════════════════
 * Global Descriptor Table (64-bit)
 * ═══════════════════════════════════════════════════════════════════════════ */

.section .rodata, "a"

/* Debug strings for early serial output */
dbg_msg_entry:
    .asciz "[ASM] Entered 64-bit mode, about to call NimMain...\n"
dbg_msg_nim:
    .asciz "[ASM] After NimMain, about to call kernelMain...\n"
dbg_msg_magic:
    .asciz "[ASM] Loading magicReg and infoPtr...\n"

.align 16
gdt:
    .quad 0x0000000000000000       /* 0x00: Null descriptor          */
    .quad 0x0020980000000000       /* 0x08: 64-bit code, ring 0      */
    .quad 0x0000920000000000       /* 0x10: 64-bit data, ring 0      */
    /* Entries below are placeholders; syscallGateInit() reloads GDTR
     * to point at the Nim-owned gdtTable which has correct values.  */
    .quad 0x0020F80000000000       /* 0x18: 64-bit code, ring 3      */
    .quad 0x0000F20000000000       /* 0x20: 64-bit data, ring 3      */
    .quad 0x0000000000000000       /* 0x28: TSS descriptor low       */
    .quad 0x0000000000000000       /* 0x30: TSS descriptor high      */
gdt_end:

.align 4
gdt_ptr:
    .word gdt_end - gdt - 1        /* limit = size - 1               */
    .long gdt                      /* base = linear address of GDT   */

/* ═══════════════════════════════════════════════════════════════════════════
 * Saved Registers (written early, read in 64-bit mode)
 * ═══════════════════════════════════════════════════════════════════════════ */

.section .data, "aw"
.align 8
magic_reg:  .long 0                 /* EAX from Multiboot entry      */
info_ptr:   .long 0                 /* EBX from Multiboot entry      */

/* ═══════════════════════════════════════════════════════════════════════════
 * BSS: Page Tables + Stack
 * ═══════════════════════════════════════════════════════════════════════════ */

.section .bss, "aw", @nobits
.align 4096
pml4:       .skip 4096              /* Page-Map Level-4 table        */
pdpt:       .skip 4096              /* Page-Directory-Pointer table  */
pd:         .skip 4096              /* Page-Directory (2 MB entries) */
stack_bottom:
            .skip 16384             /* 16 KB kernel stack            */
stack_top:

/* ── ISR common stub ──────────────────────────────────────────────────────
 * Called by per-vector entry stubs (see below).
 * On entry: stack has [rip, cs, rflags, rsp, ss] pushed by CPU (interrupt frame)
 *           plus error code and vector number pushed by the entry stub.
 * We push all GPRs, call the Nim dispatcher, pop, iretq.
 *
 * Stack layout at nimInterruptDispatch call (RSP = &rax, low addr first):
 *   rax rbx rcx rdx rsi rdi rbp r8..r15  <- pushed here (15 regs × 8 = 120 bytes)
 *   vector_num (uint64)                   <- pushed by entry stub (second)
 *   error_code (uint64)                   <- pushed by entry stub or fake 0 (first)
 *   rip cs rflags rsp ss                  <- pushed by CPU on interrupt
 */
.section .text

.global isr_common_stub
isr_common_stub:
    /* Save all general-purpose registers */
    push %rax; push %rbx; push %rcx; push %rdx
    push %rsi; push %rdi; push %rbp
    push %r8;  push %r9;  push %r10; push %r11
    push %r12; push %r13; push %r14; push %r15

    /* RSP now points at a fully-saved context layout.
     * Pass it to the Nim dispatcher (System V AMD64: first arg in RDI). */
    mov %rsp, %rdi
    call nimInterruptDispatch

    /* Restore GPRs */
    pop %r15; pop %r14; pop %r13; pop %r12
    pop %r11; pop %r10; pop %r9;  pop %r8
    pop %rbp; pop %rdi; pop %rsi; pop %rdx
    pop %rcx; pop %rbx; pop %rax

    /* Remove vector_num + error_code pushed by entry stub */
    add $16, %rsp
    iretq

/* Macro: entry stub for vectors WITHOUT an error code */
.macro ISR_NOERR num
.global isr_entry_\num
isr_entry_\num:
    push $0          /* fake error code */
    push $\num       /* vector number */
    jmp isr_common_stub
.endm

/* Macro: entry stub for vectors WITH an error code (CPU pushes it) */
.macro ISR_ERR num
.global isr_entry_\num
isr_entry_\num:
    push $\num       /* vector number (error code already on stack) */
    jmp isr_common_stub
.endm

/* Exception stubs 0-31 */
ISR_NOERR 0;  ISR_NOERR 1;  ISR_NOERR 2;  ISR_NOERR 3
ISR_NOERR 4;  ISR_NOERR 5;  ISR_NOERR 6;  ISR_NOERR 7
ISR_ERR   8;  ISR_NOERR 9;  ISR_ERR   10; ISR_ERR   11
ISR_ERR   12; ISR_ERR   13; ISR_ERR   14; ISR_NOERR 15
ISR_NOERR 16; ISR_ERR   17; ISR_NOERR 18; ISR_NOERR 19
ISR_NOERR 20; ISR_NOERR 21; ISR_NOERR 22; ISR_NOERR 23
ISR_NOERR 24; ISR_NOERR 25; ISR_NOERR 26; ISR_NOERR 27
ISR_NOERR 28; ISR_NOERR 29; ISR_ERR   30; ISR_NOERR 31

/* IRQ stubs 32-47 (hardware IRQs — no error code) */
ISR_NOERR 32; ISR_NOERR 33; ISR_NOERR 34; ISR_NOERR 35
ISR_NOERR 36; ISR_NOERR 37; ISR_NOERR 38; ISR_NOERR 39
ISR_NOERR 40; ISR_NOERR 41; ISR_NOERR 42; ISR_NOERR 43
ISR_NOERR 44; ISR_NOERR 45; ISR_NOERR 46; ISR_NOERR 47

/* Context switch stub — called from the timer ISR Nim handler.
 * Switches kernel stack from current task to next task.
 * C/Nim ABI: contextSwitch(oldRsp: ptr uint64, newRsp: uint64)
 *   RDI = pointer to where to save current RSP
 *   RSI = new RSP to load
 */
.global contextSwitch
contextSwitch:
    /* Save callee-saved registers onto current stack */
    push %rbp; push %rbx
    push %r12; push %r13; push %r14; push %r15

    /* Save current RSP into *oldRsp */
    mov %rsp, (%rdi)

    /* Switch to new stack */
    mov %rsi, %rsp

    /* Restore callee-saved registers from new stack */
    pop %r15; pop %r14; pop %r13; pop %r12
    pop %rbx; pop %rbp

    ret

/* Mark the stack as non-executable (silences linker warning) */
.section .note.GNU-stack, "", @progbits
