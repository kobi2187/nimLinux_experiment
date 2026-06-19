## SPDX-License-Identifier: GPL-2.0
##
## Runtime Library Stubs for Freestanding x86_64
##
## Provides minimal C stubs for libc functions that Nim's
## generated C code expects in freestanding (`--os:any`) mode:
##   - `memset`, `memcpy`, `memmove`, `memcmp` — memory ops
##   - `strlen`, `strcpy` — string ops
##   - `exit`, `stderr`, `fwrite`, `fflush` — error handling
##
## This module is imported by the kernel's main module to pull
## in compiled C/assembly stubs at link time.

{.compile: "rtl_stubs.c".}
{.compile: "boot_asm.S".}
