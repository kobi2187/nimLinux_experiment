# Kernel Modularity — Loadable Subsystems (Design)

## Goal

Kernel stays stable and minimal. Filesystem drivers, VFS, metadata DB, and other non-critical subsystems become **loadable modules** — code that kernel knows how to load, initialize, and wire at boot without baking them into kernel image.

## Current State (Problem)

`kernel/init/main.nim` imports directly:
- `fs/fatfs`, `fs/fatfs_write` (FatFs read/write)
- `fs/lwext4` (littlefs driver — not yet linked, scaffolding only)
- `drivers/vga_text`, `drivers/ps2_*`, `drivers/virtio/*`
- `servers/ping_server` (booting as in-kernel task)

Init sequence calls `fsMount()`, `initVirtioDevices()`, `wireVirtioNet()` directly. **Any bug in FatFs or lwext4 crashes the kernel.** Modules can't be updated without recompiling.

## Solution: Module Loader ABI

### 1. Define Module Interface (frozen)

File: `kernel/module_loader.nim`

```nim
type
  ModuleClass* = enum
    mcFilesystem   # fsMount, fsReadDir, fsWrite, etc.
    mcDriver       # device init, probe
    mcServer       # userspace task loader
    mcOther

  ModuleInfo* = object
    name*:        cstring    # "fatfs_driver", "lwext4_driver", "vfs_router"
    version*:     uint32     # semantic versioning
    class*:       ModuleClass
    init*:        proc(): bool {.nimcall.}  # returns true if successful
    deinit*:      proc() {.nimcall.}        # optional cleanup

  ModuleRegistry* = object
    modules*:     array[16, ptr ModuleInfo]
    count*:       int

var
  modReg*: ModuleRegistry

proc registerModule*(info: ptr ModuleInfo) =
  if modReg.count < 16:
    modReg.modules[modReg.count] = info
    inc modReg.count

proc loadAllModules*(): tuple[ok: int, fail: int] =
  var ok = 0
  var fail = 0
  for i in 0..<modReg.count:
    let m = modReg.modules[i]
    if m == nil: continue
    if m.init():
      inc ok
    else:
      inc fail
  (ok, fail)
```

### 2. Per-Subsystem Module File

**Example 1: FatFs Module** → `fs/fatfs_module.nim`

```nim
import ../core/log
import ./fatfs
import ./fatfs_write
import ../kernel/module_loader

var
  fsMountedModule* {.threadvar.}: bool = false

proc fatsysInit*(): bool {.nimcall.} =
  if fsMount():
    fsMountedModule = true
    klog(llInfo, "fatfs: mounted")
    return true
  klog(llWarn, "fatfs: mount failed")
  false

proc fatsysDeinit*() {.nimcall.} =
  # optional cleanup (not used yet)
  discard

var fatfsModuleInfo* = ModuleInfo(
  name: "fatfs",
  version: 0x00010000'u32,
  class: mcFilesystem,
  init: fatsysInit,
  deinit: fatsysDeinit
)

# Auto-register on link
registerModule(addr fatfsModuleInfo)
```

**Example 2: VGA Text Driver Module** → `drivers/vga_text_module.nim`

```nim
import ../kernel/module_loader
import ./vga_text
import ../core/log

proc vgaModuleInit*(): bool {.nimcall.} =
  vgaTextInit()
  klog(llInfo, "vga_text: initialized")
  true

var vgaModuleInfo* = ModuleInfo(
  name: "vga_text",
  version: 0x00010000'u32,
  class: mcDriver,
  init: vgaModuleInit,
  deinit: proc() {.nimcall.} = discard
)

registerModule(addr vgaModuleInfo)
```

### 3. Kernel Init — Load Modules, Not Direct Imports

File: `kernel/init/main.nim` (refactored)

**Before:**
```nim
import ../../fs/fatfs
import ../../fs/fatfs_write
import ../../drivers/vga_text

proc initKernelCore() =
  fsMount()          # direct call
  vgaTextInit()      # direct call
```

**After:**
```nim
# NO direct filesystem imports

import ../../kernel/module_loader
# Modules self-register when their .nim file is imported

when IsMonolithic:
  # Monolithic: link modules, kernel loads them at boot
  import ../../fs/fatfs_module       # registers fatfs module
  import ../../drivers/vga_text_module # registers vga_text module

when IsMicrokernel or IsSasos:
  # Microkernel/SASOS: filesystems run as userspace servers
  # Kernel does NOT import module files
  discard "modules load as ELF servers instead"

proc initModules() =
  let (ok, fail) = loadAllModules()
  klog(llInfo, "Modules loaded")
  klogInt(llInfo, "  ok:   ", int64(ok))
  klogInt(llInfo, "  fail: ", int64(fail))
```

### 4. Separation by Kernel Model

| Model | FatFs | VGA | Virtio | 
|-------|-------|-----|--------|
| **Monolithic** | Linked as `fatfs_module.nim` → kernel calls `loadAllModules()` | Linked as module | Linked as modules |
| **Microkernel** | Runs as `fs_server.elf` (userspace) | Runs as `display_server.elf` | Kernel only probes PCI, drivers run in servers |
| **SASOS** | Can run as kernel module OR userspace server (configurable) | Kernel module | Kernel modules (type-isolated) |

## Phase 1: Monolithic (Safe Path)

1. Create `fatfs_module.nim`, `lwext4_module.nim`, `vga_text_module.nim`, driver modules.
2. Remove direct imports from `kernel/init/main.nim`.
3. Import module files conditionally (only in monolithic mode).
4. Call `loadAllModules()` instead of direct init calls.
5. **Test:** `make test-structured` still passes; no change in behavior.

## Phase 2: Microkernel/SASOS Servers

1. Move filesystem logic into `servers/fs_server/fs_loader.nim` (loads FatFs/lwext4 as userspace code).
2. Kernel probes PCI only; doesn't load device drivers.
3. Dispatcher routes fs I/O to fs_server ELF.

## Phase 3: Hot Reload (Future)

Module registry supports dynamic load/unload (requires careful refcount + cap revocation).

## Benefits

1. **Kernel stays minimal** — core: boot, memory, scheduler, interrupts. ~500 LOC.
2. **Stability** — bug in FatFs doesn't crash kernel (monolithic still gets it at boot, but module init can fail gracefully).
3. **Composability** — per-model behavior (monolithic vs microkernel) without code duplication.
4. **Testability** — modules can be tested independently before kernel loads them.
5. **Hot updates** — filesystem driver updated without recompiling kernel (future phase 3).

## Files to Create/Modify

| File | Action | Notes |
|------|--------|-------|
| `kernel/module_loader.nim` | **CREATE** | Frozen module ABI |
| `fs/fatfs_module.nim` | **CREATE** | FatFs module wrapper |
| `fs/lwext4_module.nim` | **CREATE** | lwext4 module wrapper |
| `fs/metadata_db_module.nim` | **CREATE** (deferred) | B+ tree metadata module |
| `drivers/vga_text_module.nim` | **CREATE** | VGA text module wrapper |
| `drivers/ps2_keyboard_module.nim` | **CREATE** | PS/2 KBD module wrapper |
| `drivers/ps2_mouse_module.nim` | **CREATE** | PS/2 mouse module wrapper |
| `drivers/virtio/virtio_net_module.nim` | **CREATE** | Virtio-net module wrapper |
| `drivers/virtio/virtio_blk_module.nim` | **CREATE** | Virtio-blk module wrapper |
| `kernel/init/main.nim` | **MODIFY** | Remove direct imports; call `loadAllModules()` |

## Phasing

**Phase 1 (v0.2):** Monolithic + module loader (safety + composability).
- Unblock: virtio-pci finish (V9–V10 in sub-project).
- Then: convert monolithic to use modules (no behavior change).
- Build order: `kernel/module_loader.nim` first; then driver modules; then `kernel/init/main.nim`.

**Phase 2 (v0.3+):** Microkernel/SASOS servers load filesystems at boot.
- Requires: boot-from-disk (Milestone 1) + dispatcher (Milestone 2).

## Decision Gates

1. **Lock the ModuleInfo struct** — any change to it is cross-cutting (all modules update).
2. **Namespace modules** — all modules have unique names; registry is append-only at boot.
3. **No circular dependencies** — modules can't import each other; they depend on kernel ABI only.

## Next Step

- Write `kernel/module_loader.nim` (frozen ABI).
- Convert FatFs → `fs/fatfs_module.nim` (proof-of-concept).
- Update `kernel/init/main.nim` to use `loadAllModules()`.
- Verify `make test-structured` still passes.
