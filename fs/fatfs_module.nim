# SPDX-License-Identifier: GPL-2.0
## FatFS Module — Loadable FatFS Driver
##
## Wraps FatFS initialization as a module that can be loaded/unloaded
## via the kernel's module loader ABI.

import ../kernel/module_loader
import ../core/log
import ./fatfs

var
  fatfsModuleInfo* = ModuleInfo(
    name: "fatfs",
    version: 0x00010000'u32,  # v0.1.0
    class: mcFilesystem,
    init: proc(): bool {.nimcall.} =
      if fsMount():
        klog(llInfo, "fatfs: mounted successfully")
        return true
      klog(llWarn, "fatfs: mount failed")
      false,
    deinit: proc() {.nimcall.} =
      # Optional cleanup (not used yet)
      discard
  )

proc fatfsModuleInfoPtr*(): ptr ModuleInfo =
  ## Return pointer to the FatFS module info (for tests).
  addr fatfsModuleInfo

proc resetModuleRegistry*() =
  ## Reset module registry (for tests).
  resetRegistry()

# Auto-register on module load (when this file is imported)
registerModule(addr fatfsModuleInfo)
