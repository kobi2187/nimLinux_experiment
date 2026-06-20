# SPDX-License-Identifier: GPL-2.0
## Kernel Compile-Time Configuration
##
## Select kernel model at build time:
##   -d:kernelModel=monolithic   (default)
##   -d:kernelModel=microkernel
##   -d:kernelModel=unikernel

const
  KernelModel* {.strdefine: "kernelModel".} = "monolithic"
    ## Which kernel architecture model to compile.

  IsMonolithic*  = KernelModel == "monolithic"
  IsMicrokernel* = KernelModel == "microkernel"
  IsUnikernel*   = KernelModel == "unikernel"

  # Feature flags — override with -d:flag=true/false
  EnableSMP*     {.booldefine.} = false  ## Multi-core (SMP) support
  EnableVGA*     {.booldefine.} = true   ## VGA text mode driver
  EnablePS2*     {.booldefine.} = true   ## PS/2 keyboard driver

  MaxTasks*    = 256   ## Maximum simultaneous tasks
  MaxChannels* = 64    ## Maximum IPC channels
  MessageSize* = 256   ## Max bytes in a single IPC message
