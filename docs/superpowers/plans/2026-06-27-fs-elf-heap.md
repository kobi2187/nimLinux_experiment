# NimixOS FS + ELF + Heap Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close Milestone 1 by booting `fs_server.elf` from disk, add dynamic ELF linking (GLOB_DAT/JUMP_SLOT/PT_INTERP), and give apps a `nimixMapAnon` syscall to grow their heap beyond the initial 4 MB region.

**Architecture:** Each task is independently testable. Task 1 wires the FS server into the boot sequence so disk I/O is available before the shell starts. Task 2 extends the existing `elfLoadPie` relocation path so dynamically-linked ELFs load correctly. Task 3 adds two new ABI calls (`nimixMapAnon` / `nimixFreeAnon`) using the existing SIP bump-allocator as the backing store; no new syscall numbers are needed since we extend the existing `NimixSyscall` enum (currently 24 entries, count must stay ≤ 32).

**Tech Stack:** Nim (`--os:any`, `--os:standalone`), x86_64 bare-metal, FatFs R0.16, virtio-blk, existing region/SIP heap allocators.

## Global Constraints

- All host tests run with: `make test` (TEST_FLAGS = `--skipParentCfg --mm:refc --path:$(CURDIR) -d:noSignalHandler`)
- QEMU structured tests run with: `make test-structured`
- All 3 kernel models must build: `make build` (`-d:kernelModel=monolithic/microkernel/sasos`)
- All ELF apps build via: `make nim-apps`
- Proc body length: 5–8 lines; hard cap ~10 lines of logic (Forth philosophy — extract helpers)
- Assert invariants at entry of every non-trivial proc (preconditions, slot bounds, pointer non-nil)
- `NimixSyscallCount` must stay at 24 until Task 3, then becomes 26
- `RegionSize = 4 * 1024 * 1024` (4 MB), `MaxRegions` defined in `mm/region_allocator.nim`
- No `string` in kernel code (`--os:any`); only `cstring`, arrays, manual buffers
- Host tests use `--mm:refc`; kernel uses `--mm:arc`
- New syscall stubs go in `kernel/abi/nimix_abi_stub.c` as `__attribute__((weak))` C functions
- New ABI header declarations go in `kernel/abi/nimix_abi.h`
- Commit message prefix: `feat:` for features, `test:` for test-only changes

---

## File Map

### Task 1 — FS server boot-wiring
| File | Action | Purpose |
|------|--------|---------|
| `kernel/init/main.nim` | Modify | Replace inline `fsMount()` + `pingServerInit()` with `loadBootServers()` that reads ELFs from disk |
| `servers/fs/fs_kmod.nim` | Read-only reference | Pattern for how fs logic is wired (no changes) |

### Task 2 — ELF dynamic linking
| File | Action | Purpose |
|------|--------|---------|
| `runtime/elf_loader.nim` | Modify | Add `R_X86_64_GLOB_DAT`, `R_X86_64_JUMP_SLOT`, `R_X86_64_64` reloc handling; strip `PT_INTERP` silently |
| `tests/test_elf_loader.nim` | Modify | Add tests for new reloc types and PT_INTERP stripping |

### Task 3 — mmap ABI
| File | Action | Purpose |
|------|--------|---------|
| `arch/x86_64/syscall_gate.nim` | Modify | Add `scMapAnon = 24`, `scFreeAnon = 25`; bump `NimixSyscallCount` to 26 |
| `kernel/abi/nimix_abi_impl.nim` | Modify | Add `abiMapAnon` and `abiFreeAnon` procs |
| `kernel/abi/nimix_abi_wiring.nim` | Modify | Wire new procs into `syscallTable` |
| `kernel/abi/nimix_abi.h` | Modify | Declare `nimixMapAnon` / `nimixFreeAnon` for C apps |
| `kernel/abi/nimix_abi_stub.c` | Modify | Add weak stubs for new ABI calls |
| `tests/test_syscall_table.nim` | Modify | Assert count == 26 and new entries non-zero |
| `tests/user_tests/main.nim` | Modify | Add ring-3 test: mapAnon → write → freeAnon |

---

## Task 1: FS Server Boot-Wiring

**Files:**
- Modify: `kernel/init/main.nim` (proc `initServers`)
- Read: `shell/shell.nim` (uses `fsReadInto` + `launchElfBytes` — same pattern to reuse)
- Read: `mm/region_allocator.nim` (regionAlloc, regionBase, regionValid)
- Read: `runtime/elf_loader.nim` (elfLoadPie, AbiPatch, ElfLoadResult)

**Context:**
Currently `initServers()` in `kernel/init/main.nim` calls `fsMount()` and `pingServerInit()` but never loads `fs_server.elf` from disk. The shell later loads ELFs on demand with `cmdExec → fsReadInto → runPieElf`. The boot-wiring should mirror that pattern but run at kernel init, before the shell starts, and without a user-facing shell buffer.

The disk has `fs_server.elf` copied to it by `make disk-add-apps`. At boot, virtio-blk is already initialized (happens in `initVirtioDevices()`, before `initServers()`), so `fsMount()` will succeed immediately.

`launchElfBytes` in `shell/shell.nim` is the public API: `proc launchElfBytes*(filename: cstring; dataBuf: ptr byte; nbytes: int; args: cstring = nil)`. It allocates a region, calls `elfLoadPie`, sets up the SIP heap, spawns in ring 3.

**Interfaces:**
- Consumes: `launchElfBytes` (shell.nim), `fsMount` + `fsReadInto` (fs/fatfs.nim), `virtioBlkReady` state (set before this runs)
- Produces: `fs_server.elf` running as a ring-3 task before the shell starts; `fsMounted = true` before shell

**Done-check:** `make test-structured` boots and `fs_server: starting` appears on serial before `NimixOS>` prompt.

- [ ] **Step 1: Write a failing host test**

Add to `tests/test_fs_logic.nim` (already exists — append at end, before the final echo):

```nim
proc testFsServerBootOrder() =
  ## Boot order invariant: virtio-blk ready → fsMount → fs_server spawn.
  ## We can't test the full boot in a host test, but we can assert
  ## that fsLogicRead returns an error when the iface functions fail.
  var callOrder: seq[string]
  proc mockRead(path: cstring; buf: pointer; len: int): (int, int) {.nimcall.} =
    callOrder.add("read"); (0, 4)
  proc mockAlloc(size: uint64): int {.nimcall.} =
    callOrder.add("alloc"); 0
  proc mockFree(slot: int) {.nimcall.} = discard
  proc mockBase(slot: int): uint64 {.nimcall.} = 0x400000'u64
  proc mockGrant(slot: int; pid: uint32; right: uint32): uint64 {.nimcall.} =
    callOrder.add("grant"); 1'u64
  let iface = FsIface(readFile: mockRead, allocSlot: mockAlloc,
                       freeSlot: mockFree, slotBase: mockBase, grantCap: mockGrant)
  let r = fsLogicRead(iface, "/test.elf", 0'u32, 4096)
  assert r.err == 0,        "fsLogicRead must succeed with mock iface"
  assert callOrder == @["alloc", "read", "grant"], "call order must be alloc→read→grant"
  echo "PASS: fsLogicRead call order: alloc → read → grant"
```

Add `testFsServerBootOrder()` to the `when isMainModule:` block.

- [ ] **Step 2: Run test to confirm it compiles and passes (it's a logic test)**

```bash
nim c -r --skipParentCfg --mm:refc --path:. -d:noSignalHandler tests/test_fs_logic.nim
```

Expected: `PASS: fsLogicRead call order: alloc → read → grant` then `=== Results: 9 passed, 0 failed ===`

- [ ] **Step 3: Add `loadServerFromDisk` to `kernel/init/main.nim`**

In `kernel/init/main.nim`, replace the body of `initServers()` with a version that loads `fs_server.elf` from disk. Add these new procs **before** `initServers`:

```nim
var serverLoadBuf: array[512 * 1024, byte]   # 512 KB static buffer for server ELFs

proc tryLoadServer(name: cstring): bool =
  ## Read a server ELF from disk into serverLoadBuf and spawn it ring-3.
  ## Returns true if the server was spawned successfully.
  assert fsMounted, "disk must be mounted before loading servers"
  let (res, nbytes) = fsReadInto(name, cast[ptr byte](addr serverLoadBuf[0]),
                                  serverLoadBuf.len)
  if res != fOk:
    klog(llWarn, "boot: server ELF not found on disk")
    return false
  launchElfBytes(name, cast[ptr byte](addr serverLoadBuf[0]), nbytes)
  klog(llInfo, "boot: server spawned")
  true

proc mountDisk(): bool =
  ## Mount disk; log result. Returns true on success.
  if fsMount():
    klog(llInfo, "boot: FAT volume mounted")
    return true
  klog(llWarn, "boot: disk not available — servers will not load")
  false
```

Then rewrite `initServers()`:

```nim
proc initServers() =
  regionAllocInit()
  serverChanRegistryInit()
  pingServerInit()
  spawnInitialTasks()
  spawnDispatcher()
  if mountDisk():
    discard tryLoadServer("fs_server.elf")
```

- [ ] **Step 4: Build and confirm compilation**

```bash
make build 2>&1 | grep -E "Error|SuccessX"
```

Expected: 3× `[SuccessX]`, no errors.

- [ ] **Step 5: Build disk image with fs_server.elf and run structured test**

```bash
make nim-apps disk-add-apps test-structured
```

Expected: serial output includes `boot: FAT volume mounted` and `fs_server: starting` (from `fs_server_elf.nim`'s `write("fs_server: starting\n")`), and all structured tests still pass (`TEST DONE:`).

- [ ] **Step 6: Commit**

```bash
git add kernel/init/main.nim tests/test_fs_logic.nim
git commit -m "feat: boot-wire fs_server.elf from disk at kernel init"
```

---

## Task 2: ELF GLOB_DAT + JUMP_SLOT + PT_INTERP

**Files:**
- Modify: `runtime/elf_loader.nim`
- Modify: `tests/test_elf_loader.nim`

**Context:**
`elfLoadPie` in `runtime/elf_loader.nim` currently handles only `R_X86_64_RELATIVE` (type 8). The `applyRelative` proc in `runtime/elf_loader.nim` already has the loop structure. We extend it to also handle:

- `R_X86_64_GLOB_DAT` (6): `*slot = sym_value + addend`. For PIE apps compiled with `-shared`, this patches the GOT entry. Since our apps don't use a dynamic linker, the symbol value comes directly from the ELF's own symbol table (the symbol is defined in the same binary).
- `R_X86_64_JUMP_SLOT` (7): Same as GLOB_DAT — `*slot = sym_value`. Used for PLT entries. Addend is always 0 for JUMP_SLOT in practice.
- `R_X86_64_64` (1): `*slot = sym_value + addend`. Absolute 64-bit reference. Common in non-PIE ELFs and some PIE data sections.
- `PT_INTERP` (program header type 3): the dynamic linker path. We strip it silently (skip during PT_LOAD mapping) so ELFs compiled with a linker path don't fail.

For symbol resolution in GLOB_DAT/JUMP_SLOT/64: the symbol index is in the high 32 bits of `r_info`. We look up the symbol in `.dynsym` (found via `DT_SYMTAB` in `PT_DYNAMIC`), get `st_value`, add the relocation bias (same as `R_X86_64_RELATIVE`).

**The dynamic section already scanned for `DT_RELA`/`DT_RELASZ`/`DT_RELAENT`** in `findDynamic`. We add scanning for `DT_SYMTAB` and `DT_STRSZ` at the same time.

**Key constants (add to `runtime/elf_loader.nim`):**
```nim
const
  R_X86_64_64       = 1'u32
  R_X86_64_GLOB_DAT = 6'u32
  R_X86_64_JUMP_SLOT= 7'u32
  PT_INTERP         = 3'u32
  DT_SYMTAB         = 6'u64
  DT_STRSZ          = 10'u64
  DT_SYMENT         = 11'u64
```

**Interfaces:**
- Consumes: existing `Elf64Rela`, `Elf64Sym`, `Elf64Dyn` types; `asRela`, `asSym`, `asDyn`, `asU64` helpers (all in `runtime/elf_loader.nim`)
- Produces: `elfLoadPie` now handles GLOB_DAT/JUMP_SLOT/64/PT_INTERP; same `ElfLoadResult` return type unchanged

**Done-check:** `make test` passes (host tests for new reloc handling); a dynamically-linked ELF with PLT stubs loads without `"ELF PIE: unknown reloc type"` warnings.

- [ ] **Step 1: Write failing tests in `tests/test_elf_loader.nim`**

Open `tests/test_elf_loader.nim`. The file currently has `testBoundsOk` and `testBoundsOverflow`. Append:

```nim
import ../runtime/elf_loader

proc makeRela(offset, symIdx: uint64; relocType: uint32; addend: int64): Elf64Rela =
  Elf64Rela(r_offset: offset,
             r_info:   (symIdx shl 32) or uint64(relocType),
             r_addend: addend)

proc testGlobDatRelocType() =
  ## R_X86_64_GLOB_DAT has type 6 — verify the constant.
  assert R_X86_64_GLOB_DAT == 6'u32
  echo "PASS: R_X86_64_GLOB_DAT == 6"

proc testJumpSlotRelocType() =
  assert R_X86_64_JUMP_SLOT == 7'u32
  echo "PASS: R_X86_64_JUMP_SLOT == 7"

proc testR64RelocType() =
  assert R_X86_64_64 == 1'u32
  echo "PASS: R_X86_64_64 == 1"

proc testRelocInfoExtract() =
  ## Verify symIdx and relocType encoding in r_info.
  let rela = makeRela(0x1000'u64, 5'u64, 6'u32, 0)
  let relocType = uint32(rela.r_info and 0xFFFF_FFFF'u64)
  let symIdx    = rela.r_info shr 32
  assert relocType == 6'u32, "reloc type from r_info"
  assert symIdx    == 5'u64, "sym index from r_info"
  echo "PASS: r_info encodes symIdx and relocType correctly"
```

Add calls in `when isMainModule:`:
```nim
  testGlobDatRelocType()
  testJumpSlotRelocType()
  testR64RelocType()
  testRelocInfoExtract()
```

- [ ] **Step 2: Run tests — they should FAIL because the constants don't exist yet**

```bash
nim c -r --skipParentCfg --mm:refc --path:. -d:noSignalHandler tests/test_elf_loader.nim
```

Expected: compile error `undeclared identifier: 'R_X86_64_GLOB_DAT'`

- [ ] **Step 3: Add constants and extend reloc handling in `runtime/elf_loader.nim`**

**3a.** Add to the `const` block near the top of `runtime/elf_loader.nim`:

```nim
  R_X86_64_64*        = 1'u32
  R_X86_64_GLOB_DAT*  = 6'u32
  R_X86_64_JUMP_SLOT* = 7'u32
  PT_INTERP*          = 3'u32
  DT_SYMTAB           = 6'u64
  DT_STRSZ            = 10'u64
  DT_SYMENT           = 11'u64
```

**3b.** Add `symtabAddr` and `syment` scanning to `parseDynamic` (in `runtime/elf_loader.nim`). Current signature:

```nim
proc parseDynamic(fileBase, bias: uint64; ph: Phdr;
                  relaAddr, relaSz, relaEnt: var uint64)
```

New signature (add two more out-params):

```nim
proc parseDynamic(fileBase, bias: uint64; ph: Phdr;
                  relaAddr, relaSz, relaEnt: var uint64;
                  symtabAddr, syment: var uint64)
```

Add to the `case entry.d_tag` inside `parseDynamic`:
```nim
      of DT_SYMTAB: symtabAddr = bias + entry.d_val
      of DT_SYMENT: syment     = entry.d_val
```

Update the call site `findDynamic` to pass the new out-params:

```nim
proc findDynamic(fileBase, bias: uint64; h: Ehdr;
                 relaAddr, relaSz, relaEnt: var uint64;
                 symtabAddr, syment: var uint64) =
  for i in 0'u16 ..< h.e_phnum:
    let ph = asPhdr(atOffset(fileBase, h.e_phoff + uint64(i) * uint64(h.e_phentsize)))
    if ph.p_type == PT_DYNAMIC:
      parseDynamic(fileBase, bias, ph, relaAddr, relaSz, relaEnt, symtabAddr, syment)
      break
```

Update `applyRelocations` to pass the new out-params:

```nim
proc applyRelocations(fileBase, bias: uint64; h: Ehdr) =
  var relaAddr   = 0'u64
  var relaSz     = 0'u64
  var relaEnt    = 24'u64
  var symtabAddr = 0'u64
  var syment     = 24'u64   ## default Elf64Sym size
  findDynamic(fileBase, bias, h, relaAddr, relaSz, relaEnt, symtabAddr, syment)
  if relaAddr != 0 and relaSz > 0:
    applyAllRelocs(relaAddr, relaSz, relaEnt, bias, symtabAddr, syment)
```

**3c.** Replace `applyRelative` with `applyAllRelocs` that handles all four types:

```nim
proc symValue(symtabAddr, syment: uint64; symIdx: uint64; bias: uint64): uint64 =
  ## Look up st_value for symbol index in .dynsym, add bias.
  if symtabAddr == 0 or symIdx == 0: return 0
  let sym = asSym(symtabAddr + symIdx * syment)
  bias + sym.st_value

proc applyOneReloc(rela: Rela; bias, symtabAddr, syment: uint64) =
  let relocType = uint32(rela.r_info and 0xFFFF_FFFF'u64)
  let symIdx    = rela.r_info shr 32
  let slot      = asU64(rela.r_offset + bias)
  case relocType
  of R_X86_64_RELATIVE:  slot[] = bias + uint64(rela.r_addend)
  of R_X86_64_64:        slot[] = symValue(symtabAddr, syment, symIdx, bias) + uint64(rela.r_addend)
  of R_X86_64_GLOB_DAT:  slot[] = symValue(symtabAddr, syment, symIdx, bias) + uint64(rela.r_addend)
  of R_X86_64_JUMP_SLOT: slot[] = symValue(symtabAddr, syment, symIdx, 0) # no bias for PLT
  of 0'u32: discard   # R_X86_64_NONE
  else: klogInt(llWarn, "ELF PIE: unknown reloc type ", int64(relocType))

proc applyAllRelocs(relaAddr, relaSz, relaEnt, bias, symtabAddr, syment: uint64) =
  let count = relaSz div relaEnt
  for i in 0'u64 ..< count:
    applyOneReloc(asRela(relaAddr + i * relaEnt), bias, symtabAddr, syment)
  klogInt(llInfo, "ELF PIE: applied relocations, count=", int64(count))
```

**3d.** In `mapAllLoadSegments`, skip `PT_INTERP` segments (type 3) silently. In `mapLoadSegment`, only process `PT_LOAD`. The outer loop in `mapAllLoadSegments` already checks `if ph.p_type != PT_LOAD: continue` — verify this is the case (it should be, from the refactor). Add `PT_INTERP` to the ignored set by ensuring the skip is explicit:

The current code already has:
```nim
if ph.p_type != PT_LOAD: continue
```
That covers PT_INTERP — no change needed. But add a log line when we see PT_INTERP so it's clear it was stripped:

```nim
    if ph.p_type == PT_INTERP: klog(llInfo, "ELF PIE: PT_INTERP stripped"); continue
    if ph.p_type != PT_LOAD: continue
```

- [ ] **Step 4: Run tests**

```bash
make test 2>&1 | grep -E "=== All|FAIL|Error|PASS.*reloc|PASS.*ELF"
```

Expected: `PASS: R_X86_64_GLOB_DAT == 6`, `PASS: R_X86_64_JUMP_SLOT == 7`, `PASS: R_X86_64_64 == 1`, `PASS: r_info encodes symIdx and relocType correctly`, `=== All tests passed ===`

- [ ] **Step 5: Build all kernels**

```bash
make build 2>&1 | grep -E "Error|SuccessX"
```

Expected: 3× `[SuccessX]`, no errors.

- [ ] **Step 6: Commit**

```bash
git add runtime/elf_loader.nim tests/test_elf_loader.nim
git commit -m "feat: ELF GLOB_DAT + JUMP_SLOT + R_X86_64_64 relocs; strip PT_INTERP"
```

---

## Task 3: nimixMapAnon / nimixFreeAnon Heap Growth ABI

**Files:**
- Modify: `arch/x86_64/syscall_gate.nim`
- Modify: `kernel/abi/nimix_abi_impl.nim`
- Modify: `kernel/abi/nimix_abi_wiring.nim`
- Modify: `kernel/abi/nimix_abi.h`
- Modify: `kernel/abi/nimix_abi_stub.c`
- Modify: `tests/test_syscall_table.nim`
- Modify: `tests/user_tests/main.nim`

**Context:**
Apps currently have a fixed 4 MB region with a bump allocator (`mm/sip_heap.nim`). `sipAlloc(slot, size)` returns a pointer from the bump. There's no way for an app to request additional memory once the region fills.

`nimixMapAnon(size)` will call `sipAlloc` on the app's current region slot. The slot is identified via `procTable.current` (the currently-running task's `regionSlot` field). It returns `nil` on failure (region full or size too large). `nimixFreeAnon` is a no-op for now (bump allocator, individual frees not supported — region freed on exit).

New syscall numbers: `scMapAnon = 24`, `scFreeAnon = 25`. `NimixSyscallCount` goes from 24 → 26. The `AbiVTable` struct needs two new function pointer fields.

**Key existing procs:**
- `sipAlloc(slot: int; size: int): pointer` in `mm/sip_heap.nim`
- `procTable.tasks[procTable.current].regionSlot: int32` in `kernel/process_table.nim`
- `AbiVTable` in `kernel/abi/nimix_abi.nim` — the vtable struct; must add `mapAnon` and `freeAnon` fields

**Interfaces:**
- Consumes: `sipAlloc` (mm/sip_heap.nim), `procTable.current` + `.regionSlot` (kernel/process_table.nim)
- Produces: `nimixMapAnon(size: int): pointer` and `nimixFreeAnon(p: pointer; size: int)` as ring-3 callable ABI; `scMapAnon=24`, `scFreeAnon=25` in syscall table

**Done-check:** `make test` passes (26 table entries); `make test-structured` passes the new ring-3 `mapAnon` test.

- [ ] **Step 1: Write failing host test for syscall count**

In `tests/test_syscall_table.nim`, change the count assertion:

```nim
# Find the line:
assert NimixSyscallCount == 24, "expect 24 syscalls"
# Change to:
assert NimixSyscallCount == 26, "expect 26 syscalls after mapAnon/freeAnon"
```

Also add:
```nim
proc testMapAnonEntry() =
  syscallTableInit()
  assert syscallTable[24] != 0, "scMapAnon must be wired"
  assert syscallTable[25] != 0, "scFreeAnon must be wired"
  echo "PASS: scMapAnon and scFreeAnon wired in syscall table"
```

Add `testMapAnonEntry()` to `when isMainModule:`.

- [ ] **Step 2: Run test — it should FAIL**

```bash
nim c -r --skipParentCfg --mm:refc --path:. -d:noSignalHandler tests/test_syscall_table.nim
```

Expected: FAIL `expect 26 syscalls after mapAnon/freeAnon` (NimixSyscallCount is still 24).

- [ ] **Step 3: Add syscall numbers in `arch/x86_64/syscall_gate.nim`**

Find the `NimixSyscall` enum and the `NimixSyscallCount` const. Add two entries and update the count:

```nim
  # Add after scWallClock = 23:
  scMapAnon        = 24
  scFreeAnon       = 25

# Change:
const NimixSyscallCount* = 26
```

- [ ] **Step 4: Add vtable fields to `AbiVTable` in `kernel/abi/nimix_abi.nim`**

Find the `AbiVTable` type (it lists all ABI function pointers). Add two new fields at the end:

```nim
  mapAnon*:   proc(size: int): pointer {.nimcall.}
  freeAnon*:  proc(p: pointer; size: int) {.nimcall.}
```

- [ ] **Step 5: Implement `abiMapAnon` and `abiFreeAnon` in `kernel/abi/nimix_abi_impl.nim`**

At the end of `kernel/abi/nimix_abi_impl.nim`, add:

```nim
import ../../mm/sip_heap
import ../../kernel/process_table

proc abiMapAnon*(size: int): pointer {.nimcall.} =
  ## Allocate `size` bytes from the calling app's SIP bump heap.
  ## Returns nil if the region is full or size <= 0.
  assert size > 0, "mapAnon: size must be positive"
  let slot = int(procTable.tasks[procTable.current].regionSlot)
  assert slot >= 0, "mapAnon: current task has no region"
  sipAlloc(slot, size)

proc abiFreeAnon*(p: pointer; size: int) {.nimcall.} =
  ## No-op: bump allocator, individual frees not supported.
  ## Region is freed as a whole when the app calls nimixExit.
  discard
```

- [ ] **Step 6: Wire into `AbiVTable` in `kernel/abi/nimix_abi_wiring.nim`**

In `wireSharedAbi`, add at the end of the vtable construction:

```nim
  av.mapAnon  = abiMapAnon
  av.freeAnon = abiFreeAnon
```

Wire into `syscallTable` in `syscallTableInit` (in `arch/x86_64/syscall_gate.nim`). Find `syscallTableInit` and add at the end:

```nim
  syscallTable[ord(scMapAnon)]  = cast[uint64](av.mapAnon)
  syscallTable[ord(scFreeAnon)] = cast[uint64](av.freeAnon)
```

- [ ] **Step 7: Update C header and stub**

In `kernel/abi/nimix_abi.h`, add after the existing declarations:

```c
/* Allocate anonymous memory from the app's region heap. Returns NULL on failure. */
void* nimixMapAnon(int size);
/* Release memory (no-op for bump allocator; region freed on nimixExit). */
void  nimixFreeAnon(void* p, int size);
```

In `kernel/abi/nimix_abi_stub.c`, add weak stubs:

```c
__attribute__((weak)) void* nimixMapAnon(int size) { (void)size; return (void*)0; }
__attribute__((weak)) void  nimixFreeAnon(void* p, int size) { (void)p; (void)size; }
```

- [ ] **Step 8: Add ring-3 test in `tests/user_tests/main.nim`**

Find the existing tests (they call `testPass`/`testFail` with suite tracking). Add:

```nim
proc nimixMapAnon(size: int): pointer {.importc, cdecl.}
proc nimixFreeAnon(p: pointer; size: int) {.importc, cdecl.}

proc testMapAnon() =
  let p = nimixMapAnon(64)
  if p == nil:
    testFail("mapAnon_returns_ptr", "got nil")
    return
  # Write a sentinel and read it back
  let arr = cast[ptr array[8, uint64]](p)
  arr[0] = 0xDEAD_BEEF_CAFE_0001'u64
  if arr[0] == 0xDEAD_BEEF_CAFE_0001'u64:
    testPass("mapAnon_write_read")
  else:
    testFail("mapAnon_write_read", "readback mismatch")
  nimixFreeAnon(p, 64)
  testPass("mapAnon_free_noop")
```

Add `testMapAnon()` to the `appMain` proc alongside the existing tests.

- [ ] **Step 9: Add ABI patch entries for new syscalls in `shell/shell.nim`**

In `buildAbiPatches()`, add two entries:

```nim
  result[18] = p("nimixMapAnon",   ord(scMapAnon).uint64)
  result[19] = p("nimixFreeAnon",  ord(scFreeAnon).uint64)
```

(Array is currently sized for 18 entries `[0..17]`; update the array size to 20 and the existing comment/count.)

- [ ] **Step 10: Run host tests**

```bash
make test 2>&1 | grep -E "=== All|FAIL|Error|syscall|PASS.*map|PASS.*anon"
```

Expected: `PASS: scMapAnon and scFreeAnon wired in syscall table`, `=== All tests passed ===`

- [ ] **Step 11: Build all kernels**

```bash
make build 2>&1 | grep -E "Error|SuccessX"
```

Expected: 3× `[SuccessX]`.

- [ ] **Step 12: Run structured QEMU test**

```bash
make test-structured
```

Expected: `TEST PASS: mapAnon_returns_ptr`, `TEST PASS: mapAnon_write_read`, `TEST PASS: mapAnon_free_noop`, final `TEST DONE:` with all passing.

- [ ] **Step 13: Commit**

```bash
git add arch/x86_64/syscall_gate.nim kernel/abi/nimix_abi_impl.nim \
        kernel/abi/nimix_abi_wiring.nim kernel/abi/nimix_abi.h \
        kernel/abi/nimix_abi_stub.c kernel/abi/nimix_abi.nim \
        tests/test_syscall_table.nim tests/user_tests/main.nim \
        shell/shell.nim
git commit -m "feat: nimixMapAnon/nimixFreeAnon ABI — ring-3 heap growth via SIP bump allocator"
```

---

## Self-Review

**Spec coverage:**
- ✅ Task 1: `fs_server.elf` loaded from disk at boot before shell; `fsMount` promoted to boot sequence
- ✅ Task 2: GLOB_DAT (6), JUMP_SLOT (7), R_X86_64_64 (1), PT_INTERP strip — all BACKLOG items from TW#2/TW#7
- ✅ Task 3: `nimixMapAnon`/`nimixFreeAnon` syscalls 24/25; `NimixSyscallCount` → 26; ring-3 test; C header + stubs

**Placeholder scan:** No TBDs, no "similar to" references, no steps without code. All test assertions are concrete values.

**Type consistency:**
- `sipAlloc(slot: int; size: int): pointer` — matches `mm/sip_heap.nim` signature ✅
- `procTable.tasks[procTable.current].regionSlot: int32` — field exists in process_table.nim ✅
- `AbiVTable.mapAnon: proc(size: int): pointer {.nimcall.}` — consistent with other vtable fields ✅
- `scMapAnon = 24`, `scFreeAnon = 25` — not colliding with existing enum values ✅
- `buildAbiPatches` result array — currently 18 entries (indices 0–17); Task 3 Step 9 must verify exact current size and adjust correctly (check `shell/shell.nim:buildAbiPatches` — currently `result[17]` is the last entry, so new entries are `result[18]` and `result[19]`, array must be declared as `array[20, AbiPatch]`)

**One gap flagged:** The `buildAbiPatches` array size needs verification at implementation time — check exact current size in `shell/shell.nim` before adding entries. The implementer must read that function first.
