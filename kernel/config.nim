# SPDX-License-Identifier: GPL-2.0
## Kernel Compile-Time Configuration
##
## Select kernel model at build time:
##   -d:kernelModel=monolithic   (default) — classic single address space, all in kernel
##   -d:kernelModel=microkernel            — tiny kernel + user-space servers, hardware isolation
##   -d:kernelModel=sasos                  — Single Address Space OS (Singularity-style):
##                                           language-enforced isolation, no page-table switches,
##                                           faster IPC than microkernel, safer than monolithic

const
  KernelModel* {.strdefine: "kernelModel".} = "monolithic"
    ## Which kernel architecture model to compile.

  IsMonolithic*  = KernelModel == "monolithic"
  IsMicrokernel* = KernelModel == "microkernel"
  IsSasos*       = KernelModel == "sasos"
    ## Single Address Space OS: all processes share one address space,
    ## isolation enforced by Nim's type system rather than hardware MMU rings.

  # Feature flags — override with -d:flag=true/false
  EnableSMP*     {.booldefine.} = false  ## Multi-core (SMP) support
  EnableVGA*     {.booldefine.} = true   ## VGA text mode driver
  EnablePS2*     {.booldefine.} = true   ## PS/2 keyboard driver

  MaxTasks*    = 256   ## Maximum simultaneous tasks
  MaxChannels* = 64    ## Maximum IPC channels
  MessageSize* = 256   ## Max bytes in a single IPC message
