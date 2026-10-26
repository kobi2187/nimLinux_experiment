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
| Crash report | `kern/interrupts.nim` `fatalExceptionHandler`, `core/backtrace.nim` | BUILT | regs + frame-pointer backtrace on serial, then halt |
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
| Software rasterizer | — | PLANNED | drawRect/Line/fillRect/putPixel/blitBitmap into uint32* |
| Font rendering | — | PLANNED | stb_truetype + bitmap fallback |
| app_server / WM | — | PLANNED | windows as region caps, BeOS-style |
| Terminal emulator | — | PLANNED | VT100 subset in a GUI window |
| Desktop env | — | PLANNED | background, icons, taskbar (BeOS Tracker minimal) |
| virtio-gpu init | — | PLANNED | linear framebuffer mode |
| raylib backend | — | PLANNED | PLATFORM_CUSTOM → virtio-gpu blit |

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

**Zero-copy data path:**
```
fs_server fills region slot → mints capMemRead → sends token (MsgPack tiny)
app: regionOpen(token) → (ptr, len) → direct read → regionClose(token)
```

---

## 3. Seams under tension

| Seam | Tension | Expected move |
|------|---------|--------------|
| Address spaces | One shared space; per-region User windows | Per-app CR3 (VISION open question 6) |
| Blocking in syscalls | Interim `sti;hlt` (waitForTick) | Phase E block-on-mailbox / wake-on-deliver |
| Server-owned channel lifetime | Channel + cap survive the owning server's exit | Release on task exit (cap revocation by pid) |
| Boot sequence | disk mount timing vs server spawn | Milestone 1: resolve open question #1 |
| Virtio transport | blk driver is MMIO-only; QEMU attaches virtio-blk-pci | SPAWN virtio-pci behind VirtioTransport vtable (2026-06-27); blk+net migrate to vtable |
| virtio-gpu | driver verified; app_server not yet | Milestone 5 / roadmap B |
| Virtqueue depth | one fixed 64-entry size for all queues | per-queue size if a device needs depth (net throughput) |
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
