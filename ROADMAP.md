# NimixOS Roadmap

Last updated: 2026-06-23. Reflects architecture decisions in DECISIONS.md.

## Design principles

- **Thin kernel** — interrupt handling, context switching, memory regions, capability minting. No policy.
- **Userland services** — all I/O policy, scheduling priority, and QoS live in the dispatcher server.
- **Zero-copy data plane** — bulk data moves via capability-scoped region tokens, never through IPC buffers.
- **CPS concurrency** — dispatcher handles thousands of in-flight requests via Nim CPS continuations, no threads.
- **Apps are thin clients** — they send one MsgPack control message and wait; they never call kernel I/O directly.
- **Inspectable** — YAML for human-readable snapshots, MsgPack for control IPC, FlatBuffers for data-plane bulk.

---

## Milestone 0 — Kernel foundation ✅ DONE

Core kernel that boots, runs tasks, switches contexts correctly.

- [x] Multiboot2 boot, long mode, identity-mapped page tables
- [x] Serial I/O, PIC/PIT at 100Hz, PS2 keyboard IRQ
- [x] Three-class ring scheduler (Realtime > Server > App)
- [x] Preemptive context switch via iretq frame manipulation
- [x] FPU save/restore (fxsave64/fxrstor64) per task
- [x] TSS rsp0 updated on every switch
- [x] Per-task 4KB kernel stack with initial frame in procSpawn
- [x] Sleep/wakeAfter via procWakeExpired from PIT ISR
- [x] Idle task (hlt loop, lowest priority)
- [x] PIE ELF loader with R_X86_64_RELATIVE relocation
- [x] Virtual region allocator — 4MB slots, free-list reuse
- [x] Capability tokens — grant/revoke/check, named registry

---

## Milestone 1 — IPC and services foundation

Everything needed for apps to talk to servers reliably.

**IPC wire format**
- [ ] MsgPack wire format for ServerChan (variable length, leading u32 size)
- [ ] Validate msgpack4nim under --os:any kernel flags
- [ ] Migrate ServerChan and event pub/sub payloads to MsgPack

**Service scaffold**
- [ ] Boot: load server ELFs from disk instead of embedding in kernel
- [ ] Boot: disk mount required before server spawn
- [ ] fs_server ELF — FAT disk access via cap-gated IPC
- [ ] FatFs write support — create/write files from shell and apps
- [ ] log_server ELF — centralised log ring buffer, queryable
- [ ] roster_server — tracks running apps (name, pid, cap token)

**Testing**
- [ ] CI: GitHub Actions — build kernel, make test, make test-qemu on every push
- [ ] Preemptive switch integration test — two tasks interleave via PIT IRQ

---

## Milestone 2 — Dispatcher server

The central QoS and concurrency engine. All app I/O routes through here.

**Foundation**
- [ ] Evaluate nim-cps — verify compiles under --os:any, hello-world continuation
- [ ] FlatBuffers schema directory (dispatch.fbs, media.fbs, net.fbs)
- [ ] Minimal FlatBuffers builder/reader — stack-based, no alloc

**Core dispatcher**
- [ ] Priority queue — min-heap keyed on (class, deadline, arrival_time)
- [ ] QoS policy engine — classify by source cap + op type into 4 classes
- [ ] Starvation prevention — aging: +1 class every 500ms waiting
- [ ] dispatch_logic.nim — pure logic: CPS run loop, routing, queue
- [ ] dispatch_server_elf.nim — PIE ELF server on "dispatch" channel
- [ ] dispatch_kmod.nim — monolithic variant

**Integration**
- [ ] Serialise kernel I/O — fs_server/net_server only accept from dispatcher
- [ ] Dispatcher boot registration — capAdmin + capFs + capNet at spawn
- [ ] App-side Nim API: nimixos/fs.nim, nimixos/net.nim, nimixos/media.nim
- [ ] C header nimixos.h for WASM/C apps

**QoS classes**

| Class | Examples | Latency budget |
|-------|---------|---------------|
| Realtime | Audio output, media decode | < 5ms |
| Interactive | GUI paint, key input | < 16ms |
| Normal | File open, network request | < 100ms |
| Background | Downloads, indexing | Best-effort |

---

## Milestone 3 — Zero-copy bulk data

Apps receive a pointer into a shared region — no data copying on the I/O path.

**Capability extensions**
- [ ] Add capMemRead / capMemWrite / capMemGrant to CapRight enum
- [ ] Ref-counted region slots — regionAddRef / regionDecRef
- [ ] capGrantRegion(slot, pid, rights) — mint scoped memory cap
- [ ] nimixGrantRegion ABI proc — expose to userspace

**App-side**
- [ ] nimixos/memregion.nim — regionOpen(cap)→(ptr,len), regionClose(cap)
- [ ] C header nimixos_mem.h for non-Nim apps
- [ ] Evaluate nim-faststreams under --os:any
- [ ] nimixos/streams.nim — faststreams-backed zero-copy reader/writer

**Server-side**
- [ ] fs_server bulk read — allocate region, fill from disk, mint capMemRead, reply with token
- [ ] Dispatcher bulk reply — forward region cap token, never touch data

**Ownership model** (all expressed as cap right combinations):
- Exclusive: server holds capMemWrite, app gets capMemRead
- Shared read: server mints N capMemRead from same slot, ref-counted
- Transfer (move): server grants capMemWrite to app, revokes own
- Parent-child: parent holds capMemGrant, children get capMemRead only

---

## Milestone 4 — Stdlib and compiler target

Make normal Nim code work on NimixOS without --os:standalone hacks.

- [ ] --os:nimix Nim compiler target (replaces --os:standalone + panicoverride)
- [ ] nimix stdlib shim: osalloc.nim, osenv.nim (already partially done)
- [ ] fd table: fd 0/1/2 map to serial ABI (done)
- [ ] write(2) shim: routes fd writes to nimixWrite (done)
- [ ] Validate msgpack4nim compiles under --os:nimix
- [ ] ELF loader: R_X86_64_GLOB_DAT + R_X86_64_JUMP_SLOT (full dynamic linking)
- [ ] ELF loader: strip PT_INTERP silently

---

## Milestone 5 — Input, GUI, and terminal

Interactive user experience beyond serial shell.

**Input pipeline**
- [ ] input_server — IRQ1 PS2 handler → key events to event_server
- [ ] Translate raw scancodes to key/mouse events → app_server

**GUI**
- [ ] VirtIO-GPU driver — framebuffer mode (requires PCI bus scan first)
- [ ] PCI bus scan — enumerate devices, print vendor/device IDs
- [ ] VGA + PS2 refactor to logic/kmod/elf scaffold pattern
- [ ] Software rasteriser — drawRect, drawLine, putPixel, blitBitmap
- [ ] Font rendering — bitmap font, drawText to framebuffer
- [ ] app_server skeleton — window handles, route input to focused app
- [ ] Window manager — title bar, z-order, drag, basic compositor
- [ ] Terminal emulator window — VT100 subset, replaces serial-only shell

---

## Milestone 6 — Networking

- [ ] VirtIO-net driver — basic packet send/recv
- [ ] IP/UDP stack — minimal, enough for TFTP
- [ ] TFTP client — load ELF/WASM from QEMU TFTP server
- [ ] net_server ELF — userspace network stack, cap-gated socket API
- [ ] Dispatcher net API integration

---

## Milestone 7 — Memory hardening

- [ ] Guard pages — unmapped page before/after each app region
- [ ] ELF loader: validate segment fits within allocated region
- [ ] Heap per SIP — each app gets its own bump allocator within its region
- [ ] mmap-style ABI: nimixMapAnon(size) — grow app heap via ABI call
- [ ] Microkernel grantRegion — map physical pages into target process (requires page tables)

---

## Key architectural invariants (never violate)

1. **Apps never call kernel I/O directly** — all I/O goes through dispatcher
2. **Control plane = MsgPack** (small, inspectable), **data plane = FlatBuffers or region token** (zero-copy)
3. **Capability tokens are the only access control** — no ambient authority
4. **Region ref count reaches zero before regionFree** — no dangling pointers
5. **Dispatcher is single-threaded (CPS)** — no locks needed in hot path
6. **Kernel stays policy-free** — it executes what dispatcher says, in the order dispatcher says
