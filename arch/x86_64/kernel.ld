/* SPDX-License-Identifier: GPL-2.0 */
/* NimixOS Kernel Linker Script — x86_64
 *
 * Loads the kernel at physical address 1 MB (GRUB convention).
 * The Multiboot2 header must be within the first 32 KB of the image.
 * All sections are page-aligned (4 KB). */

OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)

SECTIONS
{
    /* ── Kernel base: 1 MB ─────────────────────────────────────────── */
    . = 1M;

    /* ── Text (code) ───────────────────────────────────────────────── */
    .text ALIGN(4K) : {
        KEEP(*(.text.boot))         /* Multiboot2 header + 32→64 stub */
        *(.text)                    /* Nim-generated code             */
        *(.text.*)
    }

    /* ── Read-only data ────────────────────────────────────────────── */
    .rodata ALIGN(4K) : {
        *(.rodata)
        *(.rodata.*)
    }

    /* ── Initialised data ──────────────────────────────────────────── */
    .data ALIGN(4K) : {
        *(.data)
        *(.data.*)
    }

    /* ── Zero-initialised data ─────────────────────────────────────── */
    .bss ALIGN(4K) : {
        *(COMMON)
        *(.bss)
        *(.bss.*)
    }

    /* ── Kernel end (used by memory manager) ───────────────────────── */
    kernel_end = .;
}
