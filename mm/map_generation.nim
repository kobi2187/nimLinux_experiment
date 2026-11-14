# SPDX-License-Identifier: GPL-2.0
## A counter the kernel's mapper bumps whenever it changes the kernel's page tables, so each task's
## private copy (mm/addr_space.nim) can tell it is stale and re-copy the kernel's entries, and a hook
## so the space that is loaded RIGHT NOW is updated at once (a driver that maps a DMA window and
## uses it in the same call must not fault on a copy that predates it).

var
  gKernelMapGen*: uint64
    ## Incremented on every change to the kernel's mappings.
  onKernelMapChanged*: proc() {.nimcall.}
    ## Set by kernel/space/kspace.nim: bring the running task's space up to date.

proc kernelMapsChanged*() =
  inc gKernelMapGen
  if onKernelMapChanged != nil: onKernelMapChanged()
