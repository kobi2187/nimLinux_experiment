/* SPDX-License-Identifier: GPL-2.0
 * Linker script for NimixOS kernel
 * Links boot.asm + compiled Nim code into Multiboot2-compliant kernel
 */

ENTRY(_start)

SECTIONS
{
    /* Multiboot2 header must be in first 32KB of kernel image */
    . = 0x0100000;  /* 1MB - common placement for kernels */

    .multiboot_header : {
        *(.multiboot_header)
    }

    /* Kernel code section */
    .text : {
        *(.text)
        *(.text.*)
    }

    /* Read-only data */
    .rodata : {
        *(.rodata)
        *(.rodata.*)
    }

    /* Initialized data */
    .data : {
        *(.data)
        *(.data.*)
    }

    /* Uninitialized data */
    .bss : {
        *(.bss)
        *(.bss.*)
        *(COMMON)
    }

    /* Discard unnecessary sections */
    /DISCARD/ : {
        *(.note.GNU-stack)
        *(.gnu_debuglink)
        *(.gnu_debugaltlink)
    }
}
