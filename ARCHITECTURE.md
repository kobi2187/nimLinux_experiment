# ARCHITECTURE.md — Living Module Map

## 1. Module tree

### Core / CPU / Hardware primitives

| Module | Path | Status | Interface |
|--------|------|--------|-----------|
| CPU primitives | `arch/x86_64/cpu_primitives.nim` | BUILT | inline procs for CR regs, MSRs, I/O ports, hlt/sti/cli |
| Atomic ops | `arch/common/atomics.nim` | BUILT | load/store/CAS/fetch-op with memory ordering |
| Bit intrinsics | `arch/common/bit_intrinsics.nim` | BUILT (no callers) | countTrailingZeros, popcount, findFirstFreeInWordOpt (ccfeb6d) |
| Core types | `core/types.nim` | BUILT | PhysAddr, VirtAddr, Result[T,E], Option[T] |
| Serial I/O | `core/serial.nim` | BUILT | serialWrite, serialPrint |
| Logging | `core/log.nim` | BUILT | klog(level, msg), log_types |
| Boot info | `arch/common/boot_info.nim` | BUILT | multiboot2 parse → BootInfo |
| Interrupts | `kern/interrupts.nim` | BUILT | IDT init, ISR registration |
| PIC | `drivers/pic.nim` | BUILT | pic init, EOI |
| PIT | `drivers/pit.nim` | BUILT | 100 Hz tick, pitUptimeTicks() |
| picolibc | `vendor/picolibc` (pinned 1.8.12), `tools/picolibc_build.sh` | BUILT (host-verified) | libc + libm for server/app ELFs; the OS layer under it (V2b `libnimix`) is PLANNED |
| TSC clock | `core/tsc_clock.nim` (pure), `drivers/tsc.nim` | BUILT | fine monotonic clock: `tscNanos()`; calibrated against PIT ch 2 at boot; exposure to apps = V3b (PLANNED) |
| PS/2 keyboard | `drivers/ps2_keyboard.nim` | BUILT | IRQ1 handler → scancode |
| VGA text | `drivers/vga_text.nim` | BUILT | 80×25 text mode |
| PCI bus scan | `drivers/pci/pci_device.nim` | BUILT | enumerate devices, vendor/device IDs |
| TSS | `arch/x86_64/` | BUILT | TSS rsp0 updated on every context switch |
| Syscall gate | `arch/x86_64/syscall_gate.nim` | BUILT | SYSCALL/SYSRET + 30-call table; one `NimixSyscallSymbol` list drives ELF patching; user RSP per-task; GDT DS-before-CS for SYSRET (2026-10-26) |

### Memory management

| Module | Path | Status | Interface |
|--------|------|--------|-----------|
| Physical allocator | `mm/physical_manager.nim` | BUILT | allocFrame / freeFrame, zone management |
| Virtual manager | `mm/virtual_manager.nim` | BUILT | map/unmap, permission mgmt |
| Heap allocator | `mm/heap_allocator.nim` / `heap_manager.nim` | BUILT | alloc/free/realloc |
| Region allocator | `mm/region_allocator.nim` | BUILT | 4 MB slots, free-list reuse, regionAlloc/regionFree |
| SIP heap | `mm/sip_heap.nim` | BUILT | per-SIP bump allocator (SASOS model) |
| Zero-copy region caps | `kernel/cap/capability.nim` (extension) | PLANNED | capGrantRegion, regionAddRef/DecRef, capMemRead/Write/Grant |
| User window | `mm/user_window.nim` | BUILT | grant/revoke ring-3 access to exactly one app region (2 MB huge-page User bit) |
| Guard pages | — | PLANNED | unmapped page before/after each app region |
| mmap-style ABI | — | PLANNED | nimixMapAnon(size) — grow app heap |

### Scheduling

| Module | Path | Status | Interface |
|--------|------|--------|-----------|
| Process table | `kernel/process_table.nim` | BUILT | 3-class ring scheduler (Realtime>Server>App), procSpawn/Ring3, procAdoptCurrent (shell is a task), 16 KB kstacks + canary |
| Task manager | `sched/task_manager.nim` | BUILT | task create/destroy, state machine |
| Scheduler trait | `kernel/traits/scheduler.nim` | BUILT | SchedulerVTable — filled by each model |
| Fiber model | `sched/fiber_model.nim` | BUILT | CPS fiber abstraction |
| Execution model | `sched/execution_model.nim` | BUILT | cooperative/preemptive toggle |

### Kernel models (scaffolding)

| Module | Path | Status | Notes |
|--------|------|--------|-------|
| Monolithic model | `kernel/models/monolithic.nim` | BUILT | Direct ring-buffer IPC, no privilege separation |
| Microkernel model | `kernel/models/microkernel.nim` | BUILT | Double-copy staging IPC, 4-band priority scheduler |
| SASOS model | `kernel/models/sasos.nim` | BUILT | Cap-gated direct copy IPC, SIP registry, Nim type isolation |
| IPC trait | `kernel/traits/ipc.nim` | BUILT | IpcVTable — filled by each model |
| Driver trait | `kernel/traits/driver.nim` | BUILT | |
| Event trait | `kernel/traits/event.nim` | BUILT | |

### IPC / Capability

| Module | Path | Status | Interface |
|--------|------|--------|-----------|
| Capability system | `kernel/cap/capability.nim` | BUILT | capGrant/Revoke/Check, CapRight enum, CapToken |
| Cap registry | `kernel/cap/cap_registry.nim` | BUILT | named cap lookup |
| ServerChan | `ipc/server_chan.nim` | BUILT | named channels; server-owned channels bound to a receive capability (`chanCreate`/`capRecv` ABI); allocation-free lookup |
| Mailbox | `ipc/mailbox.nim` | BUILT | MPSC ring primitive + named registry (2c1484d) |
| MPSC ring (lock-free) | `ipc/mpsc_ring.nim` | BUILT (no callers) | Vyukov bounded MPSC; candidate SMP backend behind Mailbox's interface (ccfeb6d) |
| Actor (CPS) | `runtime/actor.nim` | BUILT | suspend/recv/deliver — idiomatic cps park; body = `while true: suspend(); handle(recv())`; dispatcher's concurrency unit |
| SIP chan | `ipc/sip_chan.nim` | BUILT | SASOS direct-copy channel |
| Event server | `kernel/event_server.nim` | BUILT | pub/sub, nimixEventSubscribe/Poll |
| MsgPack (kernel) | `kernel/ipc/msgpack_chan.nim` | BUILT | hand-rolled, no stdlib, `--os:any` |
| **Buffers (bulk data)** | `ipc/buffers.nim` (frozen API, stub) + `ipc/buffers/` (impl: `state`, `arena`, `ring` BUILT) | **SPAWNED** → `subprojects/buffers/` (B1–B4 done) | `bufCreate/Map/Unmap/Seal/Return/Close`, `msgSend/msgRecv` with ≤4 out-of-band handles (`tmMove/tmLend/tmShare/tmTransit`), `bufRefCheck`, session rings `ringCreate/Push/Submit/Pop` (256 B slots: ≤240 B inline or a 12 B `BufRef`), `budgetAvailable`, per-model `BufEnforcer` hook. Spec: docs/proposals/bulk_data.md (FROZEN) |
| Region caps (legacy) | `kernel/cap/capability.nim` + `mm/region_allocator.nim` | BUILT, to be replaced | owner ref + last-reference release; `capMayGrantRegion`. App *images* keep regions; the data plane moves to buffers |

### Drivers

| Module | Path | Status | Notes |
|--------|------|--------|-------|
| virtio-net | `drivers/virtio/virtio_net.nim` | BUILT | virtqueue, Ethernet/IPv4/UDP stack (MMIO transport) |
| virtio-blk (MMIO) | `drivers/virtio/virtio_blk.nim` | BUILT | 3-desc chain, sync r/w; **works only on virtio-MMIO transport** |
| VirtioTransport seam | `drivers/virtio/virtio_transport.nim` | STUBBED | vtable: probe/negotiate/queueSetup/notify/readConfig/irqLine — frozen API, see DECISIONS 2026-06-27 |
| virtio-mmio transport | `drivers/virtio/virtio_mmio.nim` | PLANNED | extract existing BAR0+magic path behind VirtioTransport |
| virtio-pci transport | `drivers/virtio/virtio_pci.nim` | BUILT | modern virtio-1.0 PCI cap-walk; blk/gpu/net migrated (4d028b9); **all CommonCfg/notify/ISR access via volatile `cfgGet`/`cfgSet`/`commonKick`/`isrRead`** (V10b); sub-project `subprojects/virtio-pci/` |
| virtio-blk (PCI) | `drivers/virtio/virtio_blk.nim` | BUILT | verified in QEMU 8.2: FAT mount + ELF load from disk (V10b) |
| virtio-gpu | `drivers/virtio/virtio_gpu.nim` | BUILT | 2D scanout, responses checked; verified by screendump pixels (`make test-devices`) |
| virtio-input | `drivers/virtio/virtio_input.nim` | BUILT | evdev events → event bus topic `input` via shared-IRQ dispatcher; verified with QMP keys |
| Shared PCI IRQ | `kernel/services/init.nim` `wirePciIrq` | BUILT | per-line fan-out, ELCR level-triggered; polled drivers set INTx-disable |
| Driver registry | `kernel/driver_registry.nim` | BUILT | register/lookup by name |
| PS/2 mouse | — | PLANNED | 3/4-byte protocol, mouse.move/click events |
| RTC / CMOS | — | PLANNED | nimixUptime + nimixWallClock |
| virtio-blk | — | PLANNED | replace ATA PIO diskio.c |
| virtio-sound | `drivers/virtio/virtio_snd.nim` | BUILT | spec 5.14 tx chains, status-based completion; verified by wav recording |
| Virtqueue size | `drivers/virtio/virtqueue.nim` | BUILT | `QueueSize = 64` for every queue, stated to the device (`pciQueueAttach`) |

### Debug tooling

| Module | Path | Status | Notes |
|--------|------|--------|-------|
| QEMU launcher | `tools/nimix_qemu.py` | BUILT | only QEMU command-line builder + QMP client; used by all tests and `make qemu*` |
| Crash report | `kern/interrupts.nim` `fatalExceptionHandler`, `core/backtrace.nim` | BUILT | regs + frame-pointer backtrace on serial; user fault → kill task (hook installed by `initSyscallGate`), kernel fault → halt |
| Symbolizer | `tools/symbolize.py` | BUILT | serial log → function names (kernel + PIE apps) |
| Kernel log ring | `core/klog_ring.nim` | BUILT | last 16 KB of klog; `dmesg`, gdb `nimix-dmesg` |
| gdb helpers | `tools/gdb/nimix.gdb` | BUILT | `make gdb-attach` |
| Device self-test | `shell/devtest.nim` + `tests/qemu_devices.py` | BUILT | host-verified device effects + crash paths |

### Filesystem

| Module | Path | Status | Notes |
|--------|------|--------|-------|
| VFS Layer | `fs/vfs.nim` | BUILT | prefix router; FatFs (default `/`) + ramfs (`/ram/`) registered at boot |
| FatFs (vendor) | `fs/fatfs.nim` + vendor | BUILT | FAT16/32 read/write driver |
| littlefs driver | `fs/littlefs.nim` | PLANNED | littlefs driver mapping sectors |
| ramfs | `fs/ramfs.nim` | BUILT (no callers) | RAM block FS at `/ram/`, VFS test double (renamed from littlefs_wearleveling, DECISIONS 2026-10-26) |
| lwext4 driver | `fs/lwext4.nim` | PLANNED | lwext4 driver for ext4 large files |
| Metadata B+ Tree | `fs/metadata_db.nim` | PLANNED | Pure Nim B+ Tree for flexible tags |
| fs_server ELF | `build/apps/fs_server.elf` | PARTIAL | binary exists; boot-from-disk wiring incomplete |
| Path resolution | — | PLANNED | absolute paths, `.` and `..` handling |

### Servers (ELF userspace)

| Module | Path | Status | Notes |
|--------|------|--------|-------|
| ping_server | `servers/ping/` | BUILT | IPC demo — proves full stack |
| dispatch_server | `servers/dispatch/` | PARTIAL | CPS actor + `dispatchPump`; ELF owns `dispatch` via `chanCreate` and receives by capability — RUNS in ring 3 alongside apps (QEMU). Next: real clients + target servers (fs) |
| fs_server | `servers/fs/` | BUILT | ELF; owns `fs`; request `topic\0path\0` → event reply (≤508 B inline) |
| input_server | — | PLANNED | IRQ1 PS2 → key events → event_server |
| log_server | — | PLANNED | ring buffer, queryable |
| roster_server | — | PLANNED | tracks running apps (name, pid, cap) |
| audio_server | — | PLANNED | virtio-sound + miniaudio CUSTOM backend |
| app_server | — | PLANNED | window handles, z-order, input routing |

### Runtime / Loader

| Module | Path | Status | Notes |
|--------|------|--------|-------|
| ELF loader | `runtime/elf_loader.nim` | BUILT | PIE + R_X86_64_RELATIVE; GLOB_DAT/JUMP_SLOT planned |
| WASM runner | `runtime/wasm_runner.nim` | BUILT | wasm3; capability-gated `env.*` host calls (+`args_get`); runtime + subscriptions freed per run |
| WASM app SDK | `apps/wasm/` | BUILT | Nim → wasm32 regular apps (`hello`, `cat`); imports only NimixOS host calls |
| Task cleanup | `kernel/abi/task_cleanup.nim` | BUILT | exit/kill release region, user window, owned channels + caps, event subscriptions |
| ABI stub | `kernel/abi/nimix_abi_stub.c` | BUILT | weak symbols for nimixWrite/Exit/etc |
| ABI vtable | `kernel/abi/nimix_abi.nim` | PARTIAL | 23 calls; syscall gate dispatch is no-op |

### Shell

| Module | Path | Status | Notes |
|--------|------|--------|-------|
| Shell | `shell/shell.nim` | BUILT | serial shell; bare names resolve on disk (`name`/`.elf`/`.wasm`), launched by magic with args |
| fd table | `kernel/abi/fd_table.nim` | BUILT | fd 0/1/2 → serial ABI |
| stdlib shim | `runtime/stdlib_shim.nim` | BUILT | osalloc, write(2) → nimixWrite |

### Graphics / GUI

| Module | Path | Status | Notes |
|--------|------|--------|-------|
| Software rasterizer | `gfx/canvas.nim` | BUILT | clipped fill/rect/line/1-bpp blit/scroll over any uint32 buffer; pure lib |
| Bitmap font | `gfx/bitmap_font.nim`, `gfx/font_spleen8x16.nim`, `gfx/utf8.nim` | BUILT | Spleen 8x16 (BSD-2) generated by `tools/bdf2nim.py`; UTF-8 decoding |
| TrueType fonts | `drivers/graphics/font_render.nim` | STUBBED | unused stb_truetype binding; for userspace apps later |
| Terminal model + renderer | `term/vt.nim`, `term/term_render.nim` | BUILT | VT100/ANSI subset, damage tracking, incremental render |
| evdev keymap | `input/evdev_keymap.nim` | BUILT | US layout, shift/caps/ctrl; pure |
| Framebuffer console | `kernel/console/fb_console.nim`, `console_input.nim` | BUILT | serial mirror → VT → virtio-gpu (damaged rect); shell reads serial + keyboard |
| app_server / WM | — | PLANNED | windows as region caps, BeOS-style |
| Terminal emulator (GUI app) | — | PLANNED | window app on app_server reusing `term/` + `gfx/` |
| Desktop env | — | PLANNED | background, icons, taskbar (BeOS Tracker minimal) |
| virtio-gpu init | `drivers/virtio/virtio_gpu.nim` | BUILT | 2D scanout + `virtioGpuPresentRect` |
| raylib backend | — | PLANNED | PLATFORM_NIMIX (V5) → virtio-gpu blit of damage |
| raylib bridge | `bridge/` (P0 binding, encoder, decoder) + `build/bridge/naylib/` generated by `tools/naylib_adapt.py` | PARTIAL | naylib-compatible `raylib`/`rlgl`; direct BUILT (V7a); remote BUILT (V7b: C-symbol routing via `bridge/rl_route.nim` + `build/bridge/naylib_remote/`, loopback server `rl_server`); hybrid = per-symbol routing table, PLANNED |

---

## 2. Assembly plan — how parts connect

```
WASM/ELF app
  │ MsgPack control msg
  ▼
dispatcher_server  (CPS priority queue, 4 QoS classes)
  ├─► fs_server      ─── FAT/ext2, region cap reply (zero-copy)
  ├─► net_server     ─── IP/UDP/TCP stack
  ├─► audio_server   ─── virtio-sound + miniaudio
  ├─► input_server   ─── PS/2 → key/mouse events
  └─► event_server   ─── pub/sub wakeups (operates independently, not routed through dispatcher)

kernel scheduler
  ├─ preemptive ring (Realtime > Server > App)
  ├─ PIT 100 Hz tick → procWakeExpired
  └─ each model fills SchedulerVTable + IpcVTable

virtio-gpu ← app_server / raylib PLATFORM_CUSTOM backend
virtio-net ← net_server
virtio-blk ← fs_server (replaces ATA PIO)
virtio-sound ← audio_server
```

**Zero-copy data path (frozen 2026-10-27, implemented by subprojects/buffers):**
```
read:   app bufCreate (own budget) ──msgSend(req, [h: tmLend])──▶ dispatcher ──(tmTransit)──▶ fs_server
        fs_server bufMap → fill → reply ──▶ lend ends, app owns the filled buffer again
stream: dispatcher brokers a session → each side gets one ring end
        producer ringPush × n → ringSubmit (1 kernel call: validate, flip ownership, wake consumer actor)
small:  ≤240 B rides inline in the message / ring slot (copied; no handle)
```
Enforcement per model (`BufEnforcer`): SASOS = type system (no-op hook),
monolithic = ownership table, microkernel = page rights flipped per 2 MB
block (Stage A) → per-app CR3 (Stage B, next kernel milestone).

---

### Display path (built 2026-10-27)

```
putChar ─▶ consoleMirror ─▶ term/vt (grid + damage) ──flush (snapshot)──▶ term_render ─▶ gfx/canvas ─▶ virtio-gpu fb ─▶ PresentRect
keys: virtio-input ─▶ event "input" ─▶ console_input (input/evdev_keymap) ─▶ shell
later: app_server owns the display; GUI terminal app = same term/gfx libs in a window region
```

## Residency map (2026-11-03): where each component is vs. where it belongs

Per VISION: kernel residency is historical unless inherent. **Inherent** means
the mechanism needs CPU privilege or must be trusted by everyone: scheduling,
page tables, interrupts, capability checks, the IPC transport, buffer
enforcement. "Proper home" is the microkernel model's placement; the
monolithic model may still link a server in.

| component | today | inherent? | proper home | blocked by |
|-----------|-------|-----------|-------------|-----------|
| boot, GDT/IDT/TSS, syscall gate, interrupt dispatch, crash reports | kernel | **yes** | kernel | — |
| scheduler, process table, task cleanup, user-fault kill | kernel | **yes** | kernel | — |
| physical/virtual memory, memory windows, regions, user windows | kernel | **yes** | kernel | — |
| capabilities, server_chan/mailbox transport, event wake | kernel | **yes** (mechanism) | kernel | — |
| buffers state + enforcement, ringSubmit | kernel | **yes** | kernel | — |
| klog + serial crash output | kernel | **yes** (last-resort output) | kernel | — |
| PIT tick, PIC/IRQ routing, fine clock (V3) | kernel | **yes** | kernel (calibration is boot-time kernel work; *reading* it moves to apps via a time page, V3b) | — |
| ELF segment mapping | kernel | yes (mapping); parsing/relocation no | kernel maps; an exec/loader server parses | spawn-from-userspace syscall |
| **wasm3 runtime** (runtime/wasm_*) | kernel (shell context) | no | **per-app userspace ELF WASM host** with native helpers | slice V8 |
| **shell** (+devtest, dmesg UI) | kernel task | no | `shell.elf` (system tool) | spawn syscall; console server |
| **fb console / VT / console input** | kernel | no (a boot/panic console is the only inherent part) | console server, then the terminal app on app_server | render server (V6) |
| **virtio-gpu** | kernel driver | no | **render server** owns the display | R0 device caps; V6 |
| **virtio-snd** | kernel driver | no | **audio server** | R0; V10 |
| **virtio-input, PS/2 keyboard+mouse** | kernel drivers | no | **input_server** | R0 |
| **virtio-net + Ethernet/IPv4/UDP** | kernel | no | **net_server** | R0 |
| **virtio-blk** | kernel (polled) | no | blk driver server (or fs_server's) | R0 |
| **VFS, FatFs, ramfs** | kernel | no | **fs_server** (exists as ELF; still calls kernel FS) | blk in userspace, or lent buffers to a blk server |
| PCI scan, driver registry, module loader | kernel | partly (config-space access is privileged) | kernel grants PCI-config / MMIO / IRQ / DMA caps; a driver manager server enumerates and spawns | R0 |
| ping_server kmod, dispatch kmod | kernel modules | no | their ELF servers (both exist) | — |
| event_server topic registry (pub/sub policy) | kernel | no (wakeups are mechanism) | event server; the kernel keeps notify/wake | Phase E block-on-mailbox |
| RTC wall clock | kernel driver | no | time service | R0 |

**R0, the kernel mechanisms every driver move needs** (the
`irqSubscribe` + DMA prerequisite of VISION Q4):
- `irqSubscribe(line, cap)`, delivering to a mailbox;
- MMIO-range capabilities, mapped into the driver's space;
- DMA memory capabilities: a buffer the device may address, physical
  address known to its owner (buffers + memory windows);
- PCI config-space capabilities per device.

## 3. Seams under tension

| Seam | Tension | Expected move |
|------|---------|--------------|
| Address spaces | One shared space; per-region User windows | Stage A buffer page rights per switch → per-app CR3 (Stage B, decided 2026-10-27) |
| Blocking in syscalls | Interim `sti;hlt` (waitForTick) | Phase E block-on-mailbox / wake-on-deliver |
| Server-owned channel lifetime | Channel + cap survive the owning server's exit | Release on task exit (cap revocation by pid) |
| Boot sequence | disk mount timing vs server spawn | Milestone 1: resolve open question #1 |
| Virtio transport | blk driver is MMIO-only; QEMU attaches virtio-blk-pci | SPAWN virtio-pci behind VirtioTransport vtable (2026-06-27); blk+net migrate to vtable |
| virtio-gpu | driver verified; app_server not yet | Milestone 5 / roadmap B |
| Virtqueue depth | one fixed 64-entry size for all queues | per-queue size if a device needs depth (net throughput) |
| Display ownership | kernel fb console draws directly on the framebuffer | app_server owns the display; kernel console becomes the boot/fallback console (roadmap C) |
| `?` operator (core/types) | raises a Defect on error instead of returning it: every `?` is a panic on first failure | make `?` an early-return template (cross-cutting; audit callers) |
| Region tokens → buffer handles | fs_logic / memregion use global region tokens | migrate to `ipc/buffers` handles once the sub-project delivers (ABI change, planned) |
| FlatBuffers schema location | per-server vs shared `schemas/` | Open question #3, resolves at Milestone 2 |
| Rump kernel / OS threads for drivers | blocked on irqSubscribe + userspace DMA | Long-term; don't touch yet |

---

## 4. Drift log

| Date | What moved | ADR |
|------|-----------|-----|
| 2026-06-23 | IPC format finalised as MsgPack control + FlatBuffers data | DECISIONS.md §IPC Message Format |
| 2026-06-23 | Raylib + naylib adopted as graphics/audio foundation | DECISIONS.md §Graphics and Audio |
| 2026-06-23 | virtio adopted as primary driver model (no real hardware) | DECISIONS.md §Driver Strategy |
| 2026-06-23 | SASOS: Nim type system as isolation mechanism (no MMU rings) | DECISIONS.md §Kernel Models |
| 2026-06 | virtio-net driver + Ethernet/IPv4/UDP stack landed | git: 3862788 |
| 2026-06 | MsgPack wired into ServerChan (serverMsgFromMp/serverMsgToMp) | git: fdab067 |
| 2026-06-27 | test-structured harness fixed: skip prompt-wait in --structured; attach disk via virtio-blk-pci; pid_monotonic test corrected | (uncommitted) |
| 2026-06-27 | Virtio transport split: VirtioTransport vtable + MMIO/PCI backends; virtio-pci SPAWNED | DECISIONS.md §Virtio transport split |
| 2026-06-27 | VFS layer + B+ Tree metadata filesystem architecture introduced | DECISIONS.md §VFS and Metadata B+ Tree |
| 2026-07 | virtio gpu/net/blk migrated to PCI transport; virtio-pci sub-project effectively BUILT | git: 4d028b9 |
| 2026-07-03 | CPS actor primitive landed (`runtime/actor.nim` + `ipc/mailbox.nim`) — dispatcher's concurrency unit | DECISIONS.md §CPS actor idiom |
| 2026-07-03 | dispatcher run loop rewritten as single actor; dead ingest/route CPS loops removed; bench: 377ns/req pipeline | DECISIONS.md §Dispatcher Stage 1 |
| 2026-10-25 | virtio-pci CommonCfg/notify/ISR access made volatile; blk(pci) works end-to-end (V10 root cause) | DECISIONS.md §V10b |
| 2026-10-25 | dispatcher: transport pump + strict untrusted decode; ELF variant runs CPS via `--os:any` | DECISIONS.md §Dispatcher transport pump |
| 2026-10-25 | ccfeb6d modules recorded (mpsc_ring, bit_intrinsics, littlefs_wearleveling) — unwired | DECISIONS.md §Review of ccfeb6d modules |
| 2026-10-26 | Ring 3 works end to end (11 root causes: syscall path, scheduler, user window, heap alignment) | DECISIONS.md §Ring-3 bring-up |
| 2026-10-26 | Server-owned channels: `chanCreate`→receive cap, `capRecv`; dispatcher owns `dispatch` | DECISIONS.md §Decision principles |
| 2026-10-26 | All models allocate app memory from the app's region; dispatch_kmod/kernel CPS PARKED | DECISIONS.md §Decision principles |
| 2026-10-26 | Regular apps = WASM (Nim SDK), system tools + servers = ELF; shell resolves bare names | DECISIONS.md §Apps are WASM |
| 2026-10-26 | Task resources released on exit and kill; kernel built --panics:on; all 3 models 16/16 | DECISIONS.md §Apps are WASM |
| 2026-10-26 | One QEMU launcher; gpu/snd/net/input verified on the host; shared-IRQ + queue-size fixes; serial crash reports, symbolizer, dmesg, gdb helpers, valgrind/ASan targets | DECISIONS.md §QEMU integration |
| 2026-10-26 | Ring-3 faults kill only the task; ExceptionContext GPR order fixed (was reversed) | DECISIONS.md §User-mode faults |
| 2026-10-27 | gfx/term/input libraries + kernel framebuffer console (serial mirror, keyboard input) | DECISIONS.md §Roadmap B step 1 |
| 2026-10-27 | Bulk-data API FROZEN (`ipc/buffers.nim`); `buffers` SPAWNED; VISION Q6 resolved (Stage A page rights → Stage B per-app CR3) | DECISIONS.md §Bulk data FROZEN |
| 2026-11-03 | Buffers enforced from ring 3 (arena page rights per switch, syscalls 30–36); memory windows reserved+mapped; huge-page walk + boot-stack bugs fixed; 8 KB frame guard | DECISIONS.md §Buffers enforced |
| 2026-11-03 | Residency map: every kernel-resident component classified inherent vs historical, with proper home + blocker; R0 device-capability mechanisms identified | DECISIONS.md §Kernel residency |
| 2026-11-03 | RUI runs on the bridge (direct): bridge base = naylib adapted by a generator script to raylib 6.2 + rlsw; RUI text-engine seam (Pango | Pixie) as patches/rui2 | DECISIONS.md §V7a |
| 2026-11-03 | Remote bridge routes at the C-symbol level (`nxr_*`); one record per raylib call; raw rlgl framebuffers and shaders refused locally | DECISIONS.md §V7b |
| 2026-11-08 | Fine clock (V3): TSC calibrated against PIT ch 2; pure math separate from the driver | DECISIONS.md §V3 |
| 2026-11-09 | libc/libm for server ELFs = picolibc (no OS layer yet); raylib+rlsw need exactly 31 OS symbols | DECISIONS.md §V2 |
