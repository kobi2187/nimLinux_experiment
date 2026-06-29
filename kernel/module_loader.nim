# SPDX-License-Identifier: GPL-2.0
## Module Loader — Frozen ABI for Loadable Kernel Subsystems
##
## Modules (filesystems, drivers, servers) register themselves via ModuleInfo.
## Kernel calls loadAllModules() at boot to initialize all registered modules.
## Design: minimal, append-only registry; no circular dependencies.

type
  ModuleClass* = enum
    mcFilesystem   # filesystems (fsMount, fsRead, etc.)
    mcDriver       # device drivers
    mcServer       # userspace server loaders
    mcOther        # other subsystems

  ModuleInfo* = object
    name*:        cstring              # unique module name
    version*:     uint32               # semver as 0xMMmmpp00 (major.minor.patch)
    class*:       ModuleClass          # module classification
    init*:        proc(): bool {.nimcall.}   # init proc; ret true = success
    deinit*:      proc() {.nimcall.}         # cleanup (optional)

const MaxModules* = 16

var
  registry:      array[MaxModules, ptr ModuleInfo]
  regCount:      int = 0

proc resetRegistry*() =
  ## Reset registry (tests only).
  regCount = 0
  for i in 0..<MaxModules:
    registry[i] = nil

proc registerModule*(info: ptr ModuleInfo) =
  ## Register a module. Silently ignored if registry is full.
  if regCount < MaxModules:
    registry[regCount] = info
    inc regCount

proc registryCount*(): int =
  ## Return current registry count.
  regCount

proc loadAllModules*(): tuple[ok: int, fail: int] =
  ## Call init() on every registered module in order.
  ## Returns (success_count, fail_count).
  var ok = 0
  var fail = 0
  for i in 0..<regCount:
    let m = registry[i]
    if m == nil: continue
    if m.init():
      inc ok
    else:
      inc fail
  (ok, fail)
