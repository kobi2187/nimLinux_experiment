# ARCHITECTURE.md — Living Module Map

## 1. Module tree

### Core / CPU / Hardware primitives

| Module | Path | Status | Interface |
|--------|------|--------|-----------|
| CPU primitives | `arch/x86_64/cpu_primitives.nim` | BUILT | inline procs for CR regs, MSRs, I/O ports, hlt/sti/cli |
| Atomic ops | `arch/common/atomics.nim` | BUILT | load/store/CAS/fetch-op with memory ordering |
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
| Syscall gate | `arch/x86_64/syscall_gate.nim` | PARTIAL | SYSCALL/SYSRET wired; ABI vtable dispatch is a no-op (all apps run ring 0) |

### Memory management

| Module | Path | Status | Interface |
|--------|------|--------|-----------|
| Physical allocator | `mm/physical_manager.nim` | BUILT | allocFrame / freeFrame, zone management |
| Virtual manager | `mm/virtual_manager.nim` | BUILT | map/unmap, permission mgmt |
| Heap allocator | `mm/heap_allocator.nim` / `heap_manager.nim` | BUILT | alloc/free/realloc |
| Region allocator | `mm/region_allocator.nim` | BUILT | 4 MB slots, free-list reuse, regionAlloc/regionFree |
| SIP heap | `mm/sip_heap.nim` | BUILT | per-SIP bump allocator (SASOS model) |
| Zero-copy region caps | `kernel/cap/capability.nim` (extension) | PLANNED | capGrantRegion, regionAddRef/DecRef, capMemRead/Write/Grant |
| Guard pages | — | PLANNED | unmapped page before/after each app region |
| mmap-style ABI | — | PLANNED | nimixMapAnon(size) — grow app heap |

### Scheduling

| Module | Path | Status | Interface |
|--------|------|--------|-----------|
| Process table | `kernel/process_table.nim` | BUILT | 3-class ring scheduler (Realtime>Server>App), procSpawn, procSwitch, procWakeExpired |
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
| ServerChan | `ipc/server_chan.nim` | BUILT | named channels, MsgPack wire format, chanSend/Recv/Call |
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
| virtio-pci transport | `drivers/virtio/virtio_pci.nim` | SPAWNED | modern virtio-1.0 PCI cap-walk; sub-project `subprojects/virtio-pci/` |
| virtio-gpu | `drivers/virtio/virtio_gpu.nim` | PARTIAL | file exists, framebuffer init incomplete |
| Driver registry | `kernel/driver_registry.nim` | BUILT | register/lookup by name |
| PS/2 mouse | — | PLANNED | 3/4-byte protocol, mouse.move/click events |
| RTC / CMOS | — | PLANNED | nimixUptime + nimixWallClock |
| virtio-blk | — | PLANNED | replace ATA PIO diskio.c |
| virtio-sound | — | PLANNED | PCM output queue, virtio spec 5.14 |

### Filesystem

| Module | Path | Status | Notes |
|--------|------|--------|-------|
| VFS Layer | `fs/vfs.nim` | PLANNED | Virtual File System routing prefixes to specific drivers |
| FatFs (vendor) | `fs/fatfs.nim` + vendor | BUILT | FAT16/32 read/write driver |
| littlefs driver | `fs/littlefs.nim` | PLANNED | littlefs driver mapping sectors |
| lwext4 driver | `fs/lwext4.nim` | PLANNED | lwext4 driver for ext4 large files |
| Metadata B+ Tree | `fs/metadata_db.nim` | PLANNED | Pure Nim B+ Tree for flexible tags |
| fs_server ELF | `build/apps/fs_server.elf` | PARTIAL | binary exists; boot-from-disk wiring incomplete |
| Path resolution | — | PLANNED | absolute paths, `.` and `..` handling |

### Servers (ELF userspace)

| Module | Path | Status | Notes |
|--------|------|--------|-------|
| ping_server | `servers/ping/` | BUILT | IPC demo — proves full stack |
| dispatch_server | `servers/dispatch/` | PARTIAL | ELF exists in build/apps; CPS logic partial |
| fs_server | `apps/nim/` | PARTIAL | ELF exists; channel wiring incomplete |
| input_server | — | PLANNED | IRQ1 PS2 → key events → event_server |
| log_server | — | PLANNED | ring buffer, queryable |
| roster_server | — | PLANNED | tracks running apps (name, pid, cap) |
| audio_server | — | PLANNED | virtio-sound + miniaudio CUSTOM backend |
| app_server | — | PLANNED | window handles, z-order, input routing |

### Runtime / Loader

| Module | Path | Status | Notes |
|--------|------|--------|-------|
| ELF loader | `runtime/elf_loader.nim` | BUILT | PIE + R_X86_64_RELATIVE; GLOB_DAT/JUMP_SLOT planned |
| WASM runner | `runtime/wasm_runner.nim` | BUILT | WASM app execution |
| ABI stub | `kernel/abi/nimix_abi_stub.c` | BUILT | weak symbols for nimixWrite/Exit/etc |
| ABI vtable | `kernel/abi/nimix_abi.nim` | PARTIAL | 23 calls; syscall gate dispatch is no-op |

### Shell

| Module | Path | Status | Notes |
|--------|------|--------|-------|
| Shell | `shell/shell.nim` | BUILT | serial shell, built-ins + execApp for ELF commands |
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
| Syscall gate | Currently no-op — all apps run ring 0 | Task 48: real ring-3 transition, ABI vtable dispatch |
| Boot sequence | disk mount timing vs server spawn | Milestone 1: resolve open question #1 |
| Virtio transport | blk driver is MMIO-only; QEMU attaches virtio-blk-pci | SPAWN virtio-pci behind VirtioTransport vtable (2026-06-27); blk+net migrate to vtable |
| virtio-gpu | driver exists partially; app_server not yet | Milestone 5 |
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
