# SPDX-License-Identifier: GPL-2.0
## TSS — Task State Segment
##
## x86_64 TSS is 104 bytes. The CPU reads rsp0 on every ring-3→ring-0
## transition (syscall/interrupt from user mode) and switches the stack.
## We maintain one global TSS — enough for a single-CPU kernel.

# GDT selector constants (RPL bits included for ring-3 selectors)
const
  KernelCS*    = 0x08'u16   ## Ring 0 code segment
  KernelDS*    = 0x10'u16   ## Ring 0 data segment
  UserCS*      = 0x1B'u16   ## Ring 3 code segment (0x18 | RPL=3)
  UserDS*      = 0x23'u16   ## Ring 3 data segment (0x20 | RPL=3)
  TssSelector* = 0x28'u16   ## TSS descriptor (0x28, RPL=0)

type
  Tss* {.packed.} = object
    reserved0*:    uint32          ## offset   0
    rsp0*:         uint64          ## offset   4 — ring 0 stack pointer
    rsp1*:         uint64          ## offset  12
    rsp2*:         uint64          ## offset  20
    reserved1*:    uint64          ## offset  28
    ist1*:         uint64          ## offset  36 — interrupt stack table
    ist2*:         uint64          ## offset  44
    ist3*:         uint64          ## offset  52
    ist4*:         uint64          ## offset  60
    ist5*:         uint64          ## offset  68
    ist6*:         uint64          ## offset  76
    ist7*:         uint64          ## offset  84
    reserved2*:    uint64          ## offset  92
    reserved3*:    uint16          ## offset 100
    ioBitmapBase*: uint16          ## offset 102 — set to sizeof(Tss) to disable

var globalTss* {.exportc: "globalTss".}: Tss
  ## The single global TSS. rsp0 must be set to the kernel stack top
  ## before loading the TR register.
