# NimixOS Architecture Decisions

## Binary Formats

### ELF vs WASM assignment
- **ELF servers** (`build/apps/*.elf`): trusted OS-level components — schedulers, drivers, IPC servers, fs_server. Run in kernel address space (SASOS) or with elevated caps (microkernel). Named by convention as `<name>_server.elf` or `<name>.elf`.
- **WASM apps** (`.wasm`): user applications — sandboxed, capability-gated. Can't touch kernel data structures directly. Named as `<name>.wasm`.
- **Rationale**: WASM gives us a real sandbox boundary without hardware rings. ELF servers are trusted and need direct kernel ABI access. Both formats coexist on the FAT disk image.

### IPC Message Format: MsgPack
- **Decision**: All IPC messages between kernel and userland, and between apps, use MsgPack encoding.
- **Rationale**:
  - Inspectable (self-describing, typed) — like BMessage in BeOS but without the proprietary envelope
  - Compact binary — no parsing overhead like JSON
  - Schema-free — sender and receiver evolve independently
  - Standard (IANA-registered, cross-language) — future Nim/C/WASM apps interop cleanly
- **Scope**: ServerChan messages, event pub/sub payloads, syscall arguments (when we have real syscalls), capability grant messages.
- **NOT for**: raw bulk data transfers (use shared region + capability token for those).
- **Library split**:
  - `--os:any` (kernel): `kernel/ipc/msgpack_chan.nim` — hand-rolled, no stdlib. msgpack4nim's `streams` module needs `osalloc` which isn't available here.
  - `--os:standalone` (PIE ELF apps): **`msgpack4nim` works** — `nimix_abi_stub.c` provides the missing libc stubs (`stderr`, `exit`, `strlen`, `fwrite`, `fflush`) that Nim's `raiseOutOfMem` path needs.
  - Host tests: `msgpack4nim` directly.
- **Rule**: prefer `msgpack4nim` in apps where it works. Use `kernel/ipc/msgpack_chan.nim` only in kernel-context code (`--os:any`).

### IPC Message Size
- **Decision**: Variable-length messages with a leading size field (uint32 LE, bytes of MsgPack payload following).
- **Rationale**: Fixed-size messages waste memory for small pings and can't carry rich structured data. A leading size field lets the receiver allocate exactly what's needed and allows zero-copy forwarding.
- **Wire format**: `[u32 size][msgpack payload...]`

### Args passing to PIE ELF apps
- **Decision**: Per-region-slot kernel array (`gRegionArgs[slot][256]` in `kernel/abi/app_args.nim`).
- **Rationale**: Shared global buffer would be a race condition with thousands of concurrent fibers. Each region slot is independent. Shell writes before calling `appMain`; kernel ABI reads via `nimixGetArgs`.
- **Constraint**: 256-byte arg string limit per app invocation. Sufficient for shell commands; not for large config (use IPC for that).

## Scheduler

### Three-class ring scheduler
- **Decision**: Realtime > Server > App, intrusive doubly-linked ring per class, flat `tasks[32]` array.
- **Rationale**: O(1) pick-next without heap allocation. BeOS-inspired class separation. Monotonic PIDs (never reused) prevent kill-wrong-task bugs.
- **File**: `kernel/process_table.nim`

### procTable.current during synchronous app exec
- **Decision**: Shell sets `procTable.current` to the app's procSlot before calling `appMain`, restores it after return.
- **Rationale**: Until real preemption + context switch lands, apps run synchronously on the shell's stack. This lets `abiGetArgs` correctly identify which slot's args to return.
- **Revisit**: Once task 6 (preemption) + task 7 (context switch) land, `procTable.current` will be set by the PIT ISR on every context switch and this manual set becomes unnecessary.

## Shell

### Shell built-ins vs ELF apps
- **Built-ins** (stay in shell.nim): `help`, `version`, `meminfo`, `clear`, `model`, `exec`, `run`, `load ping`, `load pingpong`.
- **ELF apps on disk**: `ps`, `kill`, `stats`, `ls` — loaded via `execApp("X.elf", args)`.
- **Rationale**: Built-ins need direct kernel struct access or are boot-critical (help/version). Command apps benefit from being updatable without recompiling the kernel.

## Build

### nim-apps on disk image
- All `build/apps/*.elf` are copied to the FAT disk image via `make disk-add-apps`.
- `ping_server.elf` is intentionally excluded from the disk (it's spawned at boot from kernel init, not loaded on demand by the shell).

## OS Interaction Model

### Core pattern: apps talk to servers via IPC
Everything in NimixOS follows the same shape:
- **Servers** are ELF processes (ring 3, trusted) that own a resource and expose it via a named ServerChan.
- **Apps** (WASM or ELF) send requests to servers over that channel and block until a reply arrives.
- **event_server** is the pub/sub backbone: servers publish events (e.g. "file changed", "key pressed"), apps subscribe and get woken when the event fires.

This is the same model as QNX (message-passing to named servers) and BeOS (BMessage to BLooper), but with MsgPack as the wire format and capability tokens gating who can talk to whom.

### Current demos
- **ping/pingpong**: WASM app → `chanSend("ping")` → ping_server echoes reply → WASM receives it. Proves the full stack: WASM loader + ServerChan IPC + event_server pub/sub wakeup.
- These are demos only — the pattern they prove is the production pattern for every future OS service.

### Future services follow the same shape
| Service | Channel name | Events published |
|---------|-------------|-----------------|
| fs_server | `"fs"` | `"fs.changed"` |
| input_server | `"input"` | `"key.down"`, `"mouse.move"` |
| app_server | `"app"` | `"window.focus"`, `"window.close"` |
| log_server | `"log"` | — (write-only) |
| net_server | `"net"` | `"net.packet"` |

### event_server role
- Pub/sub, not RPC. Fire-and-forget notifications.
- Apps subscribe with `nimixEventSubscribe(topic)` → get a token → poll with `nimixEventPoll(token, ...)`.
- Wakes sleeping apps without busy-waiting (once sleep/wakeAfter lands — task 10).
- Not a replacement for ServerChan: use chan for request/reply, events for async notifications.

## Boot

### ping_server loaded from disk
- **Decision**: `ping_server.elf` (and all future servers) should be loaded from disk at boot, not embedded in the kernel binary.
- **Rationale**: Servers should be independently updatable. Embedding wastes kernel image space and couples server version to kernel version.
- **Path**: Boot sequence reads known server ELFs from disk, loads via `elfLoadPie`, registers in process table. Requires disk to be mounted before server init — currently disk mount is non-fatal; needs to become required for server boot.

## Dispatcher Server — Userland QoS and Concurrency Engine

### Vision

NimixOS targets **high performance, high concurrency, predictable latency, and operational simplicity**. The mechanism is a userland **dispatcher server** that centralises all app-to-service request routing and enforces QoS policy without requiring kernel changes.

### Core design goals

| Goal | How achieved |
|------|-------------|
| High throughput | CPS continuations — millions of in-flight requests, zero thread overhead |
| Predictable latency | Priority queue with per-class latency budgets (media < 5ms, GUI < 16ms, background best-effort) |
| No starvation | Aging: requests that wait too long get their priority bumped automatically |
| Simplicity | Apps are thin — they send one IPC message and wait; all policy lives in the dispatcher |
| Kernel stays minimal | Kernel I/O is serialised through the dispatcher; apps never call kernel directly for I/O |

### Architecture

```
App (WASM/ELF)
  │  send IPC request (MsgPack control / FlatBuffers data)
  ▼
dispatcher_server  ◄── policy rules (configurable)
  │  priority queue: (class, deadline, arrival_time)
  │  CPS continuation per in-flight request
  ├─► fs_server      (disk I/O, serialised)
  ├─► net_server     (network I/O)
  ├─► media_server   (audio/video decode/playback)
  ├─► input_server   (key/mouse events)
  └─► event_server   (pub/sub wakeups — operates at lower level, not routed through dispatcher)
```

Apps never speak directly to `fs_server`, `net_server`, etc. They speak only to the dispatcher. The dispatcher owns the ordering.

### Relationship to existing components

- **ServerChan** — remains the transport. Dispatcher listens on `"dispatch"` channel.
- **event_server** — operates independently at a lower level. It handles async wakeups (key pressed, file changed). The dispatcher handles request/reply I/O. These are complementary, not competing.
- **capIpc tokens** — gate who can send to the dispatcher. Untrusted apps must hold a cap.
- **`chanCall`** — apps use this for synchronous request/reply through the dispatcher.
- **kernel `procTable` priority classes** — coarse hint only (Realtime > Server > App). Fine-grained QoS policy lives entirely in the dispatcher's priority queue.

### Internal concurrency: Nim CPS

The dispatcher uses **Nim CPS** (`nim-cps`) to handle thousands of concurrent requests without OS threads. Each request becomes a `Continuation` — a heap-allocated state machine. When a request suspends (waiting for disk, waiting for a reply), it yields its continuation back to the dispatcher's run loop, which picks the next highest-priority continuation.

```nim
proc handleRequest(req: Request) {.cps: Continuation.} =
  let priority = policy.classify(req)
  await priorityQueue.enqueue(req, priority)   # suspend; yield to run loop
  let result = await kernelCall(req.op)        # suspend while I/O in flight
  await reply(req.caller, result)              # suspend until sent
```

This gives goroutine-scale concurrency with deterministic scheduling — the dispatcher's run loop is the only "thread" and it never blocks.

### Wire format: two planes

- **Control plane** (requests, capability grants, service discovery): **MsgPack** — self-describing, inspectable on serial, schema-flexible. Used for all request/reply messages.
- **Data plane** (media frames, bulk network I/O, large file transfers): **FlatBuffers** — zero-copy, fixed schema, pointer arithmetic into buffer. No parse cost on the hot path.

This mirrors the real-world split (Protobuf control + FlatBuffers data in Google's media stack, QUIC control + raw UDP data in streaming).

### QoS priority classes

| Class | Examples | Latency budget | Kernel I/O budget |
|-------|---------|---------------|-----------------|
| Realtime | Audio output, media decode | < 5ms | Preempts all |
| Interactive | GUI paint, key input | < 16ms (one frame) | Preempts background |
| Normal | File open, network request | < 100ms | Fair share |
| Background | Downloads, indexing, logging | Best-effort | Remainder |

Starvation prevention: any request waiting > 500ms gets bumped one class higher until served.

### App-side API

Apps don't see IPC directly. They use a thin Nim library:

```nim
import nimixos/media
media.play("file:///music.ogg")   # builds MsgPack msg, sends to dispatcher, waits for ack

import nimixos/net
net.download("https://...", dest) # enqueues in dispatcher as Background class
```

Non-Nim apps (C, WASM) use a header-only library that builds the same MsgPack messages and sends them over the `"dispatch"` channel.

### Kernel role

The kernel becomes a **thin hardware abstraction**:
- Handles interrupts, context switching, memory mapping
- Exposes `nimixAllocRegion`, `nimixSleep`, `nimixYield`, `nimixChanSend/Recv`
- Does NOT make policy decisions about I/O ordering or scheduling priority
- Disk/network drivers are kernel modules, but they only execute when the dispatcher says so

This makes the kernel nearly single-threaded in its I/O handling — one request in flight per device at a time — which eliminates whole classes of race conditions and makes behaviour predictable and auditable.

### Files to be created

| File | Purpose |
|------|---------|
| `servers/dispatch/dispatch_logic.nim` | Pure dispatcher logic: priority queue, CPS run loop, policy engine |
| `servers/dispatch/dispatch_kmod.nim` | Kernel module variant (monolithic) |
| `servers/dispatch/dispatch_server_elf.nim` | PIE ELF server variant (micro/SASOS) |
| `kernel/ipc/flatbuffers.nim` | Minimal FlatBuffers builder/reader for data-plane messages |
| `apps/nim/nimixos/media.nim` | Thin app-side media API |
| `apps/nim/nimixos/net.nim` | Thin app-side network API |
| `apps/nim/nimixos/fs.nim` | Thin app-side filesystem API |

## Bulk Data Transfer — Zero-Copy Memory Regions

### Problem

Moving bulk data (media frames, file contents, network payloads) through IPC message buffers requires at minimum two copies: sender → channel buffer → receiver. At 60fps 4K video (≈960 MB/s) or sustained disk I/O this is unacceptable.

### Solution: Capability-scoped memory regions

The dispatcher routes a **capability token pointing to a shared region**, not the data itself. The control path (request/reply metadata) uses MsgPack messages. The data path uses direct pointer access — zero copies.

```
App:       send {op:"read", path:"...", offset, len}   ← MsgPack, tiny
Dispatcher: route to fs_server
fs_server: fill region slot with disk data
           mint capMemRead for app's PID
           send {token, base, len} reply              ← MsgPack, tiny
App:       cast[ptr array[N,byte]](base)[]             ← zero copy, direct
App:       capRevoke(token) when done
```

In SASOS this is trivially zero-copy — all processes share one virtual address space, so the pointer is immediately valid in the app. Microkernel mode will require a `grantRegion` ABI call to establish the mapping (deferred until real page tables land).

### Memory capability rights

Extending `CapRight` in `kernel/cap/capability.nim`:

```nim
type CapRight* = enum
  capIpc         # send/recv on named channels
  capFs          # file system access
  capNet         # network access
  capAdmin       # kill tasks, spawn servers
  capMemRead     # read-only view of a specific region slot
  capMemWrite    # read-write ownership of a region slot
  capMemGrant    # can mint child caps from this region (parent only)
```

### Ownership patterns

| Pattern | Who holds what | Use case |
|---------|---------------|----------|
| **Exclusive** | Server: `capMemWrite`. App: `capMemRead` minted by server. | Normal file read |
| **Shared read** | Server: `capMemWrite + capMemGrant`. N apps each get `capMemRead`. Same region base. | Shared library, read-only cache |
| **Transfer (move)** | Server mints `capMemWrite` for app, revokes its own. | App owns buffer for encode/decode |
| **Parent-child** | Parent: `capMemWrite + capMemGrant`. Child: `capMemRead` only — cannot re-grant. | Sandboxed media decoder |

### Lifetime: reference-counted regions

`capMemRead` tokens can outlive the original `capMemWrite` holder. The region slot has a **ref count** (like `Arc<T>`):
- `capGrantRegion` increments ref count
- `capRevoke` decrements ref count
- `regionFree` only executes when ref count reaches zero

This prevents dangling pointers while allowing the server to release its own ownership without abruptly invalidating active readers.

### App-side API

```nim
# nimixos/memregion.nim
proc regionOpen*(cap: CapToken): (pointer, int)  # returns (base, len)
proc regionClose*(cap: CapToken)                  # decrements ref count
```

Non-Nim apps use the C header `nimixos.h` which provides the same interface.

### faststreams integration (future)

`nim-faststreams` (github.com/status-im/nim-faststreams) provides a zero-copy streaming API (`peek`, `advance`, `readInto`) backed by our region allocator. Apps get a `seq`-like interface without any copying. This is the long-term app-facing abstraction for streaming media and network data.

### What the dispatcher does (and doesn't do) in the data path

- **Does**: routes the control message, brokers the cap mint, forwards the token reply
- **Does not**: touch the data at all — the data path is entirely app ↔ region ↔ server

The dispatcher is on the critical path only for control (microseconds). The data path bypasses it entirely.

### Kernel role

`regionAlloc/regionFree` stay as-is. New additions:
- `capGrantRegion(slot, targetPid, rights) → CapToken` — mint a scoped memory cap
- `regionAddRef(slot)` / `regionDecRef(slot) → bool` — ref count management, returns true when hits zero

## Driver Strategy

### Virtio — primary driver model (near-term)

- **Decision**: All drivers targeting QEMU use virtio — no real hardware drivers for now.
- **Why**: Virtio is spec-driven (not quirk-driven), async-friendly (virtqueue maps to coroutine wakeup), and covers everything needed: net, block, GPU, input, entropy, serial.
- **Scope**: virtio-net and virtio-gpu are the next two drivers. virtio-net unlocks the network stack; virtio-gpu unlocks framebuffer graphics.
- **Integration point**: each virtio device is a kernel module (monolithic) or a userspace driver server (microkernel), both speaking the same virtqueue ring buffer protocol.

### Rump Kernels — future real-hardware breadth

- **Decision**: Do not attempt rump kernel port yet. Revisit when `irqSubscribe` and DMA-to-userspace mapping exist.
- **Rationale**: The `rumpuser` hypercall layer is ~1000 lines of C but requires two primitives NimixOS doesn't have yet: (1) `irqSubscribe(vec, cap)` — kernel routes interrupt to a userspace coroutine; (2) DMA-safe region mapping to userspace. Building rump before these exist means building on scaffolding.
- **Architecture**: when it lands, rump runs as a **userspace driver server** (PIE ELF process in microkernel model), not in the kernel. Kernel stays small. The boundary is a ring buffer between rump's thread world and NimixOS's coroutine world.
- **Why rump over BSD compat shim**: rump's `rumpuser` interface is a clean 20-call hypercall boundary. A BSD compat shim would require writing 5–10k lines of glue from scratch with no clean integration point.
- **Why not yet**: prerequisites are `irqSubscribe` + userspace DMA mapping, both of which emerge naturally from the microkernel driver server story. Build those first; rump slots in afterward.

### Userspace Driver Servers — microkernel endgame

- **Decision**: In the microkernel model, drivers are PIE ELF coroutine servers that own their MMIO region via cap token. Kernel routes interrupts to them via `irqSubscribe`.
- **Missing primitive**: `irqSubscribe(irqVec: int, cap: CapToken)` — kernel registers a cap-gated wakeup: when IRQ fires, resume the cap holder's coroutine.
- **DMA**: For a hobby OS, trust the driver server (no IOMMU). QEMU exposes `virtio-iommu` for safe experimentation later.

## Graphics and Audio — Raylib + naylib

### Decision: Raylib as the graphics and audio foundation

NimixOS targets game-engine-quality graphics and audio. Raylib is the chosen library because:
- Clean C codebase with a well-defined platform abstraction layer (`rcore.c`)
- Software renderer path — no GPU driver required initially
- miniaudio built-in for audio — one dependency covers both
- naylib provides idiomatic Nim bindings on top, so app code stays clean
- Raylib's `PLATFORM_CUSTOM` mode lets us replace the entire OS interface with our own

### Porting strategy

Raylib is not linked against a host OS — we provide a custom platform backend:

```
naylib (Nim API)
  └─ raylib (C library, PLATFORM_CUSTOM build)
       ├─ display → virtio-gpu framebuffer (zero-copy blit to region)
       ├─ input   → input_server IPC (key/mouse events via MsgPack)
       └─ audio   → audio_server IPC (miniaudio CUSTOM backend)
```

No X11, no Wayland, no OpenGL required. Raylib's software rasterizer draws into a raw `uint32*` framebuffer that maps directly onto the virtio-gpu display region.

### How to make raylib fast on NimixOS

The design choices that make raylib *faster* on NimixOS than on a conventional OS:

| Mechanism | What we do | Why faster |
|-----------|-----------|------------|
| **Zero-copy framebuffer** | Raylib's render target IS the virtio-gpu DMA region — no memcpy to display | Eliminates one frame buffer copy on every present |
| **Dedicated realtime task** | Raylib's game loop runs as a `tcRealtime` task in the scheduler | PIT preempts other tasks to keep frame timing consistent |
| **Direct virtqueue kick** | Present = single `virtqueueKick()` call, no syscall overhead | No kernel mode switch on every frame |
| **Zero-copy audio** | miniaudio writes directly into a region cap, audio_server reads it | No copy on audio buffer handoff |
| **No compositor overhead** | Apps that own the full screen (games) bypass the window manager entirely, rendering directly to the framebuffer | Removes compositor blit + z-order compositing cost |
| **Cap-gated exclusive display** | A game app holds `capMemWrite` on the display region — no contention | No lock/unlock on every frame, no shared surface management |
| **Coroutine-friendly design** | Raylib's `BeginDrawing/EndDrawing` maps to yield points — game loop is a coroutine, not a spinning thread | Cooperative yield between frames, no wasted CPU during vsync wait |

### Dependency chain

```
Task 16: virtio-gpu framebuffer init
  └─ Task 46: raylib rcore platform backend (PLATFORM_CUSTOM → framebuffer blit)
       ├─ Task 47: raylib software renderer
       └─ Task 48: raylib input wiring (input_server → raylib key/mouse state)
            └─ Task 50: naylib integration + validation
Task 51: audio_server ELF
  └─ Task 49: miniaudio custom backend → audio_server IPC
       └─ Task 52: hello-raylib.elf demo (draw + sound = full stack proof)
```

### "Fits like a glove" — NimixOS primitives ARE the platform layer

The goal is zero impedance mismatch. Every raylib platform call maps directly to a NimixOS primitive with no translation shim:

| Raylib platform call | NimixOS primitive | Notes |
|---------------------|------------------|-------|
| `CORE.Window.currentFbo` framebuffer ptr | `regionAlloc()` region cap → virtio-gpu display region | render target = DMA buffer, no copy |
| `PollInputEvents()` | `nimixEventPoll("input")` → key/mouse structs | input_server publishes; raylib reads same structs |
| `SwapScreenBuffer()` | `virtqueueKick(displayQueue)` | one write to a port, nothing else |
| `InitAudioDevice()` | open `"audio"` ServerChan + `capGrantRegion` for audio buffer | miniaudio custom backend owns a region cap |
| `WaitTime(seconds)` | `nimixSleep(ticks)` | maps directly to scheduler sleep |
| `GetTime()` | `pitUptimeTicks() / 100.0` | PIT tick counter, no libc needed |
| `TraceLog()` | `klog()` / `"log"` ServerChan | kernel log in kernel context, log_server in app context |

This means: the `rcore_nimixos.c` platform backend has **no abstractions of its own** — it is just thin glue that names our primitives. If a NimixOS primitive changes, one line in the backend changes. No layers to keep in sync.

### naylib vs raw raylib C

App code uses naylib (the Nim bindings). The port work happens entirely in `rcore_nimixos.c` — naylib sits on top unchanged. Apps never touch C directly.

### Input event type reuse

Raylib's `KeyboardKey` and `MouseButton` enums will be adopted as NimixOS's canonical input event types (published by input_server). This means apps that use naylib get input events with no conversion — the type coming off the wire *is* the raylib enum. No `case` statement mapping one enum to another.

### Software renderer vs GPU

Initially: raylib software rasterizer → virtio-gpu as dumb framebuffer (no 3D acceleration needed).
Later: when virtio-gpu virgl (3D) lands, raylib switches to OpenGL ES 2 via virgl. Only the present path in `rcore_nimixos.c` changes — app code is untouched.

## Open Questions

- UNCONFIRMED: Exact boot sequence for disk-loaded servers — does the kernel wait for disk mount before spawning servers, or retry asynchronously?
- UNCONFIRMED: Does the dispatcher use IST (Interrupt Stack Table) entries for its realtime class, or is PIT-driven preemption sufficient?
- UNCONFIRMED: FlatBuffers schema ownership — defined per-server or in a shared `schemas/` directory?

## QEMU debug tooling — autopsy + scalpel + automation (2026-06-28)

**Why:** serial-log grepping (`timeout + tail + grep`) was failing us — truncated
captures, ANSI noise, overwritten logs, and total blindness to silent faults /
triple faults (a checked testMode kernel produced a 0-byte log; a disk boot looked
fine on serial while actually trapping #UD forever). Researched QEMU debugging best
practices (QEMU GDB-stub + QMP docs, OSDev) and built reusable tooling.

**Built:** `tests/qemu_debug.py` (no external deps — raw-socket QMP) + Makefile targets:
- `make debug-log [DISK=] [UNTIL=regex]` — AUTOPSY. Boots with
  `-d int,cpu_reset,guest_errors -no-reboot -no-shutdown`, captures the QEMU event
  log + a de-ANSI serial transcript, and prints a *deduplicated* fault summary:
  exceptions collapsed by (vector, RIP) with counts, naming the vector (#UD/#GP/#PF/
  #DF…) and flagging fault loops. Caps the event log at 8 MB and bails early on a
  fault loop (an infinite exception otherwise fills the disk). `debug-log-test` = same
  on the testMode kernel.
- `make debug-gdb [DISK=]` — SCALPEL. Boots paused with the GDB stub (`-s -S`, :1234)
  and writes a `.gdbinit` that loads kernel symbols, sets breakpoints (kernelMain,
  panic, virtioBlkRead, virtioBlkInitPci) and a `vq` helper to dump used.idx.
  `set architecture i386:x86-64` for the 64-bit kernel.
- `make debug-qmp [UNTIL=] [MONITOR="info registers"]` — AUTOMATION. Boots with a QMP
  socket, waits for a serial pattern, runs a human-monitor command, quits cleanly.

**Validated on a real bug its first run:** boot traps `#UD invalid-opcode RIP=0x101e`
(RAX=0x3701) in an infinite loop — invisible to the old serial method. DETERMINISTIC
(3/3 runs; reproduces on danger AND checked builds, with AND without disk). Fires right
after `vfs: registered driver lwext4` — i.e. in `mountDisk()`→`vfsMount()` (kernel/init/
main.nim:333). RIP=0x101e is just past `_start` (0x100018) in the boot-stub low-memory
region — NOT valid kernel code → almost certainly a **corrupted function pointer /
return address** jumping into the boot stub. NOTE: this is a SEPARATE bug from the V10
timeout — the V10 fix is correct and *unblocked reaching it* (mount path now executes
because the disk read completes instead of timing out). Next: `make debug-gdb`, break at
vfsMount/mountDisk, step to the bad indirect jump. Likely in the fatfs/vfs/metadata_db
mount path (note metadata_db's known kernel-only seq/string corruption — may be related).

**Principle going forward:** on any silent fault / hang / triple-fault, run
`make debug-log` FIRST (autopsy) before reading serial; use `debug-gdb` to step
through logic bugs.

## SMP — Single-CPU constraint (2026-06-26)

**Current state:** Single CPU only. Two places encode this assumption:
- `syscallScratchRsp` (`arch/x86_64/syscall_gate.nim`) — plain global, saves user RSP on syscall entry
- `globalTss` (`arch/x86_64/tss.nim`) — single TSS, rsp0 updated on every context switch

**When SMP arrives — what to do:**

1. Define a `CpuLocal` struct in `arch/x86_64/cpu_local.nim`:
   ```nim
   type CpuLocal* {.packed.} = object
     selfPtr*:     pointer   # points at itself (used by swapgs)
     kernelRsp*:   uint64    # kernel stack top for this CPU (= TSS.rsp0)
     scratchRsp*:  uint64    # replaces syscallScratchRsp
     cpuId*:       uint32
   ```
2. Allocate one `CpuLocal` per CPU at AP boot; set `MSR_GS_BASE` to its address on each CPU.
3. In `syscall_entry` (boot_asm.S): replace `mov %rsp, syscallScratchRsp(%rip)` / `mov globalTss+4(%rip), %rsp` with `swapgs` + GS-relative loads:
   ```asm
   swapgs
   mov  %rsp, %gs:16     # save user RSP into CpuLocal.scratchRsp
   mov  %gs:8,  %rsp     # load CpuLocal.kernelRsp
   swapgs                 # restore user GS before call
   ```
4. Replace `globalTss` array/struct with one TSS per CPU, embedded in or adjacent to `CpuLocal`. Scheduler updates `cpuLocal[cpuId].tss.rsp0` on each context switch.
5. `syscallTable` stays global — it is read-only after `syscallTableInit()` and safe to share across CPUs.
6. AP bringup sequence: BSP sends INIT+SIPI, AP runs a startup stub that sets GS base, loads its per-CPU GDT+TSS, enables interrupts, then enters the scheduler idle loop.

**Resolving signal:** When APIC + SIPI AP bringup is started (adds `arch/x86_64/apic.nim` + `smp_boot.S`).

## Test Infrastructure — architecture and migration plan (2026-06-26)

### Current state (phase 1 — baked-in)

`tests/kernel_tests/main.nim` is compiled directly into the kernel binary via
`when defined(testMode)`. `make test-structured` builds `build/kernel-test`
(monolithic + `-d:testMode`), boots it, and parses `TEST PASS/FAIL/DONE` lines
from serial via `qemu_harness.py --structured`.

**Why baked-in first:** zero infrastructure cost; works without disk; lets us
build and validate the test protocol before adding loader complexity.

### Phase 2 — disk-loaded separate binary (target: after boot-from-disk lands)

`kernel_tests.elf` becomes a standalone PIE ELF on the disk image, loaded in
testMode before the shell via `elfLoadPie` — same path as `fs_server.elf` and
`dispatch_server.elf`. The `when defined(testMode)` call site in `kernelMain`
changes from a direct proc call to a disk load + jump. Test code is unchanged.

**Why:** tests become independently updatable without recompiling the kernel.
This mirrors the driver registry pattern — tests attach at runtime like drivers
are probed at runtime.

### Phase 3 — all 3 kernel models

Each model needs scaffolding to expose the same testable surface:

| Test | Monolithic | Microkernel | SASOS |
|------|-----------|-------------|-------|
| regionAlloc/Free | direct | direct (kernel space) | direct |
| capGrant/Check | direct | direct | direct (SIP cap) |
| procSpawn/Kill | direct | direct | direct |
| ServerChan send/recv | direct | double-copy via staging buffer | cap-gated direct copy |
| Ring-3 syscall path | procSpawnRing3 → iretq | procSpawnRing3 → iretq | procSpawnRing3 → iretq (type-isolated) |

Microkernel and SASOS IPC have different internal mechanics but the same
observable ABI — the user_tests ELF (ring-3) already covers this because it
exercises only the syscall ABI, not internal structs. The kernel_tests ELF
may need model-specific `when IsMonolithic` / `when IsMicrokernel` branches
for the IPC tests, or a shared adapter that maps to each model's internal API.

**Scaffolding plan:** Define a `TestIpcAdapter` in `tests/kernel_tests/ipc_adapter.nim`
with procs `testChanCreate/Post/Recv` that dispatch to the right model's
implementation. Each model wires it in its init. Tests call the adapter — same
test code runs on all 3 models.

### Ring-3 user test ELF

`tests/user_tests/main.nim` — compiled as a PIE ELF with `--os:standalone`,
linked against `nimix_abi_stub.o`. Runs in ring 3 via `procSpawnRing3`.
Exercises the full syscall path: trampoline → `syscall` → `syscall_entry` asm
→ dispatch table → kernel proc → `sysretq` → ring 3.
Works identically on all 3 kernel models because it only touches the ABI.
Added to testMode boot sequence after kernel_tests completes.

**Resolving signal for phase 2:** boot-from-disk (Milestone 1, open question #1).
**Resolving signal for phase 3:** when microkernel and SASOS model parity is targeted.

## Virtio transport split — MMIO vs PCI; SPAWN virtio-pci driver (2026-06-27)

### Context
While verifying Task 1 (boot fs_server from disk), `make test-structured` was fixed
to attach `disk.img` via `-device virtio-blk-pci`. The existing `virtio_blk.nim`
then failed at `blkFindMmio` with "BAR0 not MMIO or missing". Root cause: the
driver is written for the **virtio-MMIO transport** (virtio spec §4.2 — flat BAR0
with `VirtioRegMagic`/`VirtioRegStatus` register window), but `virtio-blk-pci` is a
**virtio-PCI transport** device (spec §4.1) — no MMIO magic register; configuration
is discovered via PCI capabilities (CommonCfg/Notify/ISR/Device) spread across BARs.
The two transports are incompatible at the register-access layer.

### Decision
1. **Introduce a `VirtioTransport` vtable seam** (`drivers/virtio/virtio_transport.nim`).
   The block driver and `virtqueue.nim` become transport-agnostic and call through it.
2. **Extract** the existing MMIO path into `virtio_mmio.nim` implementing the vtable.
3. **Write a new** `virtio_pci.nim` implementing the modern (virtio-1.0) PCI transport
   via the capability walk. This is the spawned sub-project (its own VISION/BACKLOG/
   STATE/DECISIONS under `subprojects/virtio-pci/`); first task is a SURVEY for a
   mature minimal virtio-pci reference to adapt.
4. `virtio_blk.nim` keeps its **frozen public API** unchanged:
   `virtioBlkInit*(): bool`, `virtioBlkRead*/Write*(sector,buf): bool`, `gVirtioBlkReady*`.
   `virtioBlkInit` gains transport selection (try PCI-modern, fall back to MMIO).

### Rejected alternatives
- *Extend virtio_blk.nim in place* — would tangle two transports in one file, against
  the code-size/complexity rules; the user asked for a separate modern driver.
- *Standalone virtio_blk_pci.nim with no vtable* — duplicates read/write logic; the
  vtable lets virtio-net adopt the same seam later.
- *Attach the disk as virtio-mmio in QEMU to match the old driver* — works short-term
  but virtio-pci is what real and standard QEMU targets use; worth doing properly.

### Why SPAWN
The PCI cap-walk + BAR mapping + modern queue setup is a self-contained module behind
one clean interface (the vtable). It fits the SPAWN profile: large, self-contained,
reachable through a single frozen API. Parent (fs boot-from-disk) proceeds against the
stub until the sub-project satisfies the vtable.

### The frozen seam (VirtioTransport)
```nim
# drivers/virtio/virtio_transport.nim
type VirtioTransport* = object
  probe*:      proc(): bool {.nimcall.}              # discover device, map regs/BARs
  negotiate*:  proc(features: uint64): bool {.nimcall.}  # status handshake + FEATURES_OK
  queueSetup*: proc(idx: uint16; ringPhys: uint64): bool {.nimcall.}
  notify*:     proc(idx: uint16) {.nimcall.}         # kick a queue
  readConfig*: proc(off: uint32): uint32 {.nimcall.} # device-specific config space
  irqLine*:    proc(): uint8 {.nimcall.}
```
(Exact field set may tighten during the sub-project's first task; any change to this
struct is cross-cutting and logged in BOTH this file and the sub-project's DECISIONS.)

### Drift
Block driver moves from single-file MMIO to transport-vtable + two backends. See
ARCHITECTURE.md drift log 2026-06-27.

## TW#24 osenv stub — obsolete, no work needed (2026-06-27)

**Survey result:** The backlog assumed msgpack4nim fails under `--os:standalone`
because of a missing `getenv`/`os` import, requiring an `osenv.nim` stub. Reproduced
the actual compile in `apps/nim/` (its `nim.cfg` + `panicoverride`): msgpack4nim
**compiles cleanly AND a full `pack`/`unpack` round-trip of an object-with-string
links with no error** (exit 0, no `getenv`/`std/os` reference). The `MsgStream` path
msgpack4nim uses does not pull in `std/os`. **Decision:** close TW#24 as already
satisfied; do not add an unnecessary stub (would be dead code against the
stdlib-preference + complexity rules). If a future `streams`-backed path reintroduces
the dependency, revisit then.

## testMode ELF load is not interrupt-safe — cli/sti around the load (2026-06-27)

**Bug:** In testMode, after kernel_tests completed, the boot hung non-deterministically
while loading `user_tests.elf` (the hang point moved between runs — different ABI-patch
numbers each time: 7/10/3/11). Earlier mistaken as a serial-flush/timeout artifact;
log-growth sampling proved a real hang (output froze at a fixed point, 14s+ idle).

**Root cause:** The hang point being *non-deterministic* proved it was asynchronous —
an interrupt (PIT at 100Hz, or another IRQ) firing during `launchElfBytes`
(ELF segment copy + relocation + ABI-stub patching + ring-3 `procSpawnRing3`). That
path is not interrupt-safe; a handler firing mid-load hangs the system. Confirmed by
wrapping the load in `cli()`/`sti()`: 3/3 runs then deterministically patch all 20
stubs and reach "App spawned in ring 3".

**Fix:** `cli()` / `sti()` around `launchElfBytes` in `runTestMode`
(`kernel/init/main.nim`). Scoped to testMode; the normal boot loads servers before
`enableInterrupts()` so it wasn't exposed. **Broader implication:** the loader/spawn
path should be made re-entrant or run under a lock before it's used with interrupts
live in production (e.g. shell `execApp`). Logged as a known sharp edge.

**Residual (separate task):** even with the load fixed, the spawned ring-3 app does not
execute its tests (no `suite=user_tests` output) — a scheduling/yield issue in the
testMode two-phase boot, tracked separately. Task 3's ring-3 mapAnon verification waits
on that.

## VFS and Metadata B+ Tree (2026-06-27)

### Context
To support files larger than 4GB (the FAT limit) and support flexible metadata tagging (like BeOS BFS attributes), we need a better filesystem block layer (such as LittleFS and/or LwExt4) and a tag-query database. We want the tag database to be pure Nim.

### Decision
1. **Virtual File System (VFS) Layer:**
   Introduce a unified, prefix-routed VFS interface in `fs/vfs.nim`. 
   FileSystem drivers (FatFs, littlefs, lwext4) register themselves with a path prefix (e.g. `/fat/`, `/lfs/`, `/ext/`). The kernel-side ABI delegates all filesystem reads, writes, and directory listings through the VFS prefix router, falling back to the primary `/fat/` volume if no prefix matches.
2. **Metadata B+ Tree Database:**
   Implement a pure Nim on-disk page-structured B+ Tree in `fs/metadata_db.nim` to index schema-less metadata tags.
   - The index is stored as a file `/metadata.db` on any underlying filesystem.
   - The tree keys are formatted as `key:value:fileId` to allow $O(\log N)$ range-based prefix queries (e.g. searching for all files with tag `artist:Daft Punk`).
   - The file contents (blobs) are stored on the underlying block filesystem (littlefs or lwext4) named by their unique file IDs.
3. **Decoupled Architecture:**
   The database runs entirely on top of the VFS block-filesystem abstraction, making it database-independent of the underlying storage format.


## CPS actor idiom — suspend/plant/resume; {.cursor.} self-ref (2026-07-03)

### Context
12 POC iterations (see `experiments/actor_poc/`, memory
`reference_cps_mechanics.md`) tried a looping actor that pops its own mailbox
inside the cpsMagic. All variants hit stale re-processing or one-behind
delivery. Root cause: iterator (yield-out) and actor (handle-in) are duals —
a break-point placed for "pause when value ready" stops BEFORE the handler
leg for handle-in, so the handler either never ran or re-ran stale state.

### Decision
`runtime/actor.nim` uses the idiom from nim-works/cps `examples/coroutine.nim`:
- `suspend()` cpsMagic is a dumb park — stores `a.suspended = a`, reads nothing.
- Sender plants the message into `a.pending` BEFORE `resume()`.
- Body reads via `recv()` (cpsVoodoo) AFTER suspend returns — always fresh.
- Body shape: `while true: suspend(); handle(recv())`.

Message consumption moved from the magic into the body removes the duality
mismatch entirely. Verified: `tests/test_actor.nim` — 4 sequential deliveries,
correct order, no duplication, no loss.

### {.cursor.} on the self-reference
`suspended* {.cursor.}: Actor` — plain field made an uncollectable ARC ref
cycle (`CycleCreated` warning; every parked actor leaked). `{.cursor.}` marks
it a non-owning view: safe because it points at the continuation itself and
`deliver` nils it before resume — lifetime strictly contained. Warning gone,
test still green.

### Constraint
nim-cps requires `--mm:arc --panics:on` — incompatible with the host-test
default `--mm:refc` (`make test`). Actor test runs standalone:
```
nim c --skipParentCfg --os:linux --mm:arc --panics:on --path:. \
  --nimcache:.nimcache_actor -r tests/test_actor.nim
```
(Same class as `make test-arc` dispatcher tests.)

### Rejected alternatives
- Looping actor with internal mailbox pop in the magic (POCs 1–11) — the
  duality bug above.
- ORC instead of {.cursor.} — nim-cps targets arc; cycle collector unnecessary
  for a lifetime-contained self-view.

## Dispatcher Stage 1 — single actor run loop; peek-then-pop backpressure (2026-07-03)

### Context
`dispatch_logic.nim`'s two CPS loops (`ingestRequests`/`dispatchRequests`)
had no suspend point — under a trampoline they spin forever; they also had
zero callers. The actor primitive (DECISIONS §CPS actor idiom) provides the
missing park/wake surface.

### Decision
ONE long-lived dispatcher actor replaces both loops:
- body: `while true: suspend(); case kind: request → ingest | tick →
  dispatchTick; drain()`
- transport delivers `MailMsg` events: `mkRequestMsg(wire)` / `mkTickMsg()`
- `drain` forwards queued requests in priority order, **peek-then-pop**: a
  request is popped only after its send succeeds. Backpressured requests
  stay queued with their original `arrivalTick`, so QoS aging keeps running
  while they wait. (First drafted pop-then-requeue — rejected: requeue
  restamps arrival, resetting the aging clock; caught by test_actor_tick_aging.)
- send failure (`iface.send < 0`) = backpressure signal; retry on next wake.
`priority_queue.nim` / `qos_policy.nim` unchanged.

### Benchmark (make bench-arc, release)
Full pipeline (deliver → msgpack decode → classify → pqPush → drain: peek,
encode, send, pop → re-park): **~377 ns/request ≈ 2.7M req/s single-threaded**.
Actor machinery ~60 ns; MsgPack encode+decode ~310 ns. Realtime QoS budget
(5ms) is ~13,000× the pipeline cost — design carries the performance; no
micro-tuning warranted.

### Stage 2 (deferred)
Per-request continuations with reply correlation (DECISIONS' `handleRequest`
sketch) when request/reply + cap-gating land (Milestone 2). Bench says
affordable: 328 B + ~60 ns per in-flight request.

### Rejected alternatives
- Two actors (ingest + route): route has nothing to park on while sends are
  fire-and-forget — a seam with no payoff.
- Pop-then-requeue drain: resets aging clock (above).

## V10b — virtio-pci CommonCfg needs volatile access; root cause of blk timeouts (2026-10-25)

### Context
Every virtio-blk(pci) request timed out (`used.idx` never advanced), so `mount`,
`ls`, `exec` — the whole disk path — were dead. The V10 "uncached DMA ring" fix
had not cured it; the author's own `qemu_test.log` also stops at the first sector
read.

### Evidence (QEMU 8.2, TCG)
- `-trace virtio_*`: status reaches 15 (DRIVER_OK) and QEMU *receives* both
  notifies, but never pops a buffer.
- HMP `info virtio-queue-status`: device holds `desc=0x19d8000` (correct) but
  **`avail=0, used=0`**. QEMU latches all three ring addresses on the
  `queue_enable=1` write.
- `objdump` of `commonQueueSetup`: GCC emitted select → descLo → **enable** →
  descHi → avail (merged 64-bit) → used. Plain stores through `ptr` to a struct
  are reorderable/mergeable/eliminable; an uncached mapping only stops CPU
  caching, not the compiler. `writeGuestFeatures`' first `select=0` is likewise a
  dead store the compiler may drop.

### Decision (SURVEY: adopt `std/volatile`, the Nim analogue of Linux readl/writel)
- `cfgGet`/`cfgSet` templates in `virtio_pci.nim`; every CommonCfg access in
  virtio_pci, the PCI transport, gpu, net, snd, input goes through them.
- `notifyWrite` = compiler barrier + volatile 16-bit store (Linux virtio_wmb +
  iowrite16); `isrRead` volatile (a discarded plain load is deleted outright, yet
  the read is what acks the IRQ); `deviceConfigRead32` volatile.
- `commonKick` selects the queue before reading `queue_notify_off` — that field
  reads back for the *selected* queue and QEMU derives the kicked queue from the
  doorbell address, so the old code could kick the wrong queue (net RX after TX
  setup). Latent; fixed in the same pass.

### Result
`mount` → "FAT volume mounted"; ELFs load from disk. QEMU harness 4/11 → 5/11
(remaining failures cascade from the pre-existing post-ring-3-spawn hang, TW#65).

### Rejected
- `asm volatile("" ::: "memory")` between every store — works, but one forgotten
  barrier silently reintroduces the bug; per-access volatile is local and auditable.
- Marking the `common` pointer target `{.volatile.}` — Nim applies it to the
  variable, not pointee fields.

## Dispatcher transport pump + strict untrusted decode (2026-10-25)

### Decision
- `dispatchPump(ds, actor)` in `dispatch_logic.nim`: one quantum = drain up to
  `PumpMaxPerQuantum` (64) messages from `iface.recv("dispatch")` into the actor,
  then deliver one tick. Transport-neutral — kmod and ELF variants share it. A
  recv that fills the buffer may be truncated (`abiChanRecv` copies min) → dropped.
- `tryDecodeRequest` in `dispatch_wire.nim`: strict hand decoder for
  `[uint, uint]`. msgpack4nim validates shape with `assert` → AssertionDefect →
  fatal under `--panics:on`, so one malformed app message killed the dispatcher
  (caught by a new test). `decodeRequest` kept for trusted callers.
- ELF variant builds with `--os:any --panics:on` (CPS on): nim-cps references
  `getCurrentException`, which system.nim omits for `hostOS == "standalone"`.
  Four libc no-ops added to `nimix_abi_stub.c` (ferror, clearerr, strerror,
  __errno_location) for syncio error paths — same pattern as the existing
  fwrite/fflush stubs. Verified: links with only `_start` unresolved (like every
  app), RELATIVE relocs only, loads + spawns in ring 3 in QEMU.

### Not done — cross-cutting, needs dialogue
- No `"dispatch"` ServerChan is ever registered and the ABI has no way for an ELF
  to register one: the ELF dispatcher receives nothing until a `chanCreate` ABI
  call (or kernel-side pre-registration) exists.
- kmod variant: running CPS in the kernel needs `--panics:on` on the kernel build
  and a boot hook; deferred.

## Capability table valid when zero-initialised (2026-10-25)
`capTableInit` is never called by the kernel, so `nextSerial` started at 0 and the
first grant minted `makeToken(0, 0) == NullCap` (in-kernel tests
`cap_grant_not_null`/`cap_check_right` failed). `capGrant` now skips serial 0
*before* minting, making the zero value valid without an init call. Regression
test `testGrantOnZeroInitTable` (fails before, passes after). Structured suite 24/24.

## Build portability + stale-kernel trap (2026-10-25)
- Hardcoded `/home/kl/prog/...` paths in `fs/fatfs.nim`, `runtime/wasm_*.nim`
  replaced with `{.compile.}` paths relative to the module and `currentSourcePath`
  -derived `-I` flags; Makefile `NIM ?= nim`; nimble path in `TEST_FLAGS`.
- `build/kernel-%` and `build/kernel-test` listed no prerequisites, so edits never
  rebuilt them (`make iso` booted a stale kernel; `make test-structured` ran an old
  one). Both now depend on `FORCE`; nim's own cache keeps rebuilds fast.
- `kernel/init/main.nim` testMode branch lost its `process_table`/`pit` imports in
  the c6d7425 refactor and no longer compiled; restored.

## Review of ccfeb6d modules (2026-10-25)
`ipc/mpsc_ring.nim` (Vyukov bounded MPSC), `arch/common/bit_intrinsics.nim`,
`fs/littlefs_wearleveling.nim` landed with no callers and no ADR. Tests pass and
are now wired into `make test` / `make test-arc`. Flags for the human:
- `mpsc_ring` duplicates `ipc/mailbox.nim`'s role; it is the natural SMP backend
  for Mailbox behind Mailbox's unchanged interface — swap when SMP (open question
  #5) starts, not before (single-CPU cost with no benefit today).
- `littlefs_wearleveling` is a 16 KB in-RAM toy FS registered at `/lfs_wl/`, not
  littlefs. It conflicts with §VFS (vendor real littlefs/lwext4) and had no SURVEY.
  Keep as a VFS test double or delete — human's call.

## Decision principles from the human (2026-10-26)
"Decisions should match the general vision: microkernel, functionality in
servers, actors and lightweight fibers, capabilities, and libraries for an
oskit, modular and encapsulated. Not a POSIX OS-threads type of operating
system. Some prerequisites are allowed to enable the basis." Recorded in
VISION.md as design axioms; the four open calls of 2026-10-25 resolved by it:

| Call | Resolution | Rejected |
|------|-----------|----------|
| Who creates the dispatch channel | Server creates it: `chanCreate(name)` → receive capability; `capRecv(tok)`; plain `chanRecv` refused on owned channels | Kernel pre-registration (policy in kernel); pid-based receive check (ambient authority) |
| `--panics:on` in kernel for dispatch_kmod | PARKED. Dispatcher is a userspace server; no CPS runtime in the kernel | Changing kernel flags for a kmod variant the microkernel path doesn't need |
| littlefs_wearleveling | Renamed `ramfs` (honest oskit VFS lib / test double); real littlefs after Nim-ecosystem survey | Delete (loses a useful test double); keep misleading name |
| mpsc_ring | PARKED as Mailbox's SMP backend; fibers are single-CPU today | Adopting now (cost, no benefit, OS-thread test harness only) |

## Ring-3 bring-up — eleven root causes (2026-10-26)
Method: QEMU `-d int`, HMP, gdb backtraces, objdump — every fix has evidence.
TW#72 "RIP=0x101e" was REAL, not stale. In discovery order:
1. **Trampoline** 12 B, no `ret`/`mov r10,rcx` → ran stub leftovers after
   sysret. → 16 B complete function; loader refuses stubs < 16 B.
2. **Patch table** hand list 20/28 → single `NimixSyscallSymbol` table +
   test cross-checking `nimix_abi_stub.c`.
3. **syscall_entry** arg shuffle swapped a2/a3.
4. **First switch** to a ring-3 task `ret` to 0 → kstack starts with
   `isr_restore`.
5. **User RW/X**: boot map has no User bit → `mm/user_window` grants the
   app's own region at spawn, revokes at exit. Interim: one shared address
   space; per-app CR3 remains the real isolation step (OPEN, see VISION).
6. **TLS**: Nim threads:on → `%fs` loads, FS=0 → apps `--threads:off`
   (matches "no OS threads").
7. **Shell not a task** (current=-1) → `procAdoptCurrent`; exit/sleep/yield
   block with `sti;hlt` (`waitForTick`) so the PIT does the real switch.
   Interim until Phase E block-on-mailbox/wake-on-deliver.
8. **fxsave** buffer unaligned (#GP) → `{.align(16).}`.
9. **Kernel stack overflow**: 4 KB kstack, `abiProcList` copied a whole Task
   (>4 KB frame) into procTable → 16 KB stacks, in-place `claimSlot`, ptr
   reads, canary checked every tick.
10. **GDT order**: SYSRETQ needs user data before user code; got CS=0x2B
    (TSS) → #GP(0x28) on the next ring-3 IRQ. Standard layout (DS 0x1B,
    CS 0x23, STAR[63:48]=KernelDS). Shared `syscallScratchRsp` → user RSP
    now on the task's own kstack.
11. **Heap**: apps never ran `NimMain` (`--noMain`) → `nimixAppInit()`;
    Nim's standalone heap is `array[float64]` → 8-aligned in EVERY binary,
    so `p & ~PageMask` found wrong chunk headers (also the likely root of the
    kernel "seq/string corruption" sharp edge). SURVEY: adopt Nim's own
    `-d:nimAllocPagesViaMalloc` for apps (page-aligned arena malloc);
    kernel keeps its malloc (wasm3 needs it; it logs via Nim strings so it
    can't back Nim's allocator) and page-aligns `theHeap` via
    `-fdata-sections` + kernel.ld. `tests/check_heap_alignment.sh` runs in
    `make build`/`nim-apps`. Rejected: patching stdlib; linker trick for apps.
Also: allocRegion gave apps kernel heap in mono/micro → all models allocate
from the app's region; nim-cps tracing off for the dispatcher ELF (4096-entry
trace deque per continuation in debug builds).

### Result
Structured 41/41 (user_tests 17/17 — first ring-3 suite run); harness 10/11;
dispatcher + apps concurrent, zero faults. Known open: `ls` → fsReadDir("/")
fails (FS layer); kernel string compare failed before the heap fix — kernel
strings should be re-verified (metadata_db sharp edge).

## Apps are WASM, system + servers are ELF; everything works end to end (2026-10-26)
Human: "Regular apps are wasm, servers and system are elf." Implemented:

- **Shell** resolves a bare name on disk: `name`, `name.elf`, `name.wasm`;
  launches by magic (`\x7fELF` / `\0asm`), passes args to both. The hard-coded
  ls/ps/stats/kill commands are gone (they are just ELF tools now).
- **Nim → WASM app SDK** (`apps/wasm/`): `--cpu:wasm32` via clang +
  wasm32-wasi *headers only* (apt wasi-libc); `nimix_wasm_rt.c` supplies the
  libc corner Nim needs, so a module imports ONLY `env.*` NimixOS calls —
  enforced by `tests/test_wasm_apps.py`. Same entry rules as ELF apps
  (NimMain first; page-aligned arena via nimAllocPagesViaMalloc; 1 MB — Nim's
  first page request is ~516 KB). SURVEY: rejected linking WASI libc (would
  import wasi_snapshot_preview1 — ambient OS authority the sandbox must not
  have) and writing apps in C (keeps the OS one language).
- **Client/server pattern for WASM apps** (already used by pingpong): send to
  a server channel (needs CapIpc), reply as an event on a client topic.
  fs_server protocol: `"<topic>\0<path>\0"` → event: int32 status + ≤508 B.
  Larger reads → zero-copy region caps once WASM can map regions (seam).
- **Servers own channels** (`chanCreate`/`capRecv`) and yield when idle.
- **Ownership-scoped cleanup** (`kernel/abi/task_cleanup.nim`): exit AND kill
  release region + user window, owned channels + their capabilities, and event
  subscriptions; WASM modules release their subscriptions when they end. Fixes:
  killed server could never restart; subscriptions leaked (256-run limit).
- **Every model works**: procTableInit was monolithic-only → micro/sasos
  booted with a corrupt scheduler table and kernelMain silently returned.
- **Kernel `--panics:on`** + `rtl_stubs` stderr → serial: a failed check now
  prints and halts instead of unwinding silently out of kernelMain (that is
  how the microkernel failure hid). Overrides the 2026-10-26 "PARKED" note for
  a different reason: fatal-and-visible kernel defects, not CPS.
- VFS drivers registered at boot (FatFs default `/`, ramfs `/ram/`) — `ls`.
- wasm3 runtime/env freed per run (leaked every launch), 64 KB value stack.
- Per-request virtio TRACE output gated behind `-d:virtioTrace`.

Verified: host + ARC + WASM host tests; structured 41/41; QEMU harness
16/16 on microkernel, SASOS and monolithic; kill/restart/duplicate scenarios.

## QEMU integration, virtio drivers verified on the host, debug tooling (2026-10-26)

Request: improve QEMU integration and the virtio drivers; enable valgrind and
debugging tools over serial and natively.

**One QEMU launcher** — `tools/nimix_qemu.py` (library + CLI) is now the only
place that builds a QEMU command line: device set (`blk net gpu snd input |
all`), display, accel (KVM when available), serial, gdb stub, QMP (unix
socket client with `screendump`/`send_key`/`hmp`), event log, pcap, wav.
`tests/qemu_harness.py`, `tests/qemu_debug.py`, `tests/qemu_devices.py` and
the Makefile `qemu*` targets all use it (four duplicated command lines and a
second QMP client removed). SURVEY: rejected the `qemu.qmp` PyPI package (an
extra dependency for ~40 lines) and libvirt (far heavier than the need).

**Devices are verified by their effect on the host, not the guest's word**
(`make test-devices`, `shell/devtest.nim`): gpu → screendump pixels of four
colour bars; snd → wav recording at ~440 Hz; net → our UDP marker in a pcap;
input → keys injected via QMP arrive as evdev codes through the IRQ path.
Writing that test exposed six real driver bugs, all fixed:
1. **virtio-gpu showed nothing**: `gpuSubmitCmd` spun on a non-volatile
   `used.idx` (hoisted load → "done" before the device answered); responses
   were never checked. Now acquire-load + per-command OK_NODATA check, and the
   framebuffer has its own DMA allocation (it overran the 3 ring pages by 4 MB).
2. **virtio-snd**: wrong request codes/enums, event+tx sharing a ring, non-spec
   tx chains → rewritten to spec 5.14 (3-descriptor xfer/data/status chains).
3. **Queue size mismatch (all virtio-pci devices)**: drivers assumed 256-entry
   rings but never wrote `queue_size`; snd/input default to 64, so ring indices
   diverged after 64 entries (QEMU: "Desc next is 64" → device broken).
   `QueueSize = 64` for every queue and the driver states it
   (`pciQueueAttach` → `commonQueueSetup(..., ringSize)`, additive API — see
   subprojects/virtio-pci DECISIONS). Rejected per-queue sizes for now: the
   ring arrays are typed by the constant; revisit if a queue needs depth.
4. **Shared INTx lines**: the slave PIC cascade (IRQ2) was never unmasked, the
   lines were edge-triggered, and polled devices (blk/gpu/snd) raised the
   shared line with nobody acknowledging it — after blk's first interrupt line
   11 stayed high and net/input never interrupted again. Now: per-line fan-out
   dispatcher (`wirePciIrq`), ELCR level-triggered PCI lines, IRQ2 unmasked,
   polled drivers set PCI Command.InterruptDisable, IRQ drivers read their ISR.
5. **snd completions**: QEMU 8.2 fills tx used entries without publishing
   used.idx; completion is taken from the per-request status the device writes
   (spec-valid), and `virtioSndFinish` cycles STOP/RELEASE/PREPARE/START to
   hand back the last held period. Sounds are padded to whole periods.
6. Init order: virtio before modules/filesystems (FAT mounts at boot).

**Debugging over serial**: every CPU exception (except #DB/NMI/#BP) prints a
crash report — vector, error code, CR2/CR3, all registers, frame-pointer
backtrace — and halts (previously only 4 vectors had handlers and they
*returned*, re-faulting forever). Nim runtime panics (`rtl_stubs.c exit/abort`)
print a backtrace too. The kernel builds `-fno-omit-frame-pointer`.
`tools/symbolize.py` names frames from the ELF (`nm`; `addr2line` lines with
`make DEBUG=1`), apps via the logged PIE load bias. `dmesg` shows a 16 KB
klog ring (`core/klog_ring.nim`). `devtest crash-pf|crash-ud|crash-panic`
exercise the whole path in `make test-devices`.

**Debugging natively**: `make test-valgrind` (memcheck, `-d:useMalloc`) and
`make test-asan` (ASan + UBSan) run every host test; the host-test list is
now one Makefile variable shared by `test`/`test-valgrind`/`test-asan`.
UBSan's first run found a real defect: the per-task kernel stack started
4 bytes past an 8-byte boundary (misaligned canary, misaligned stack base) →
`kstack {.align(16).}`. `make qemu-debug` + `make gdb-attach` load
`tools/gdb/nimix.gdb` (nimix-bt frame-pointer backtrace without debug info,
nimix-dmesg, nimix-sym, nimix-app for PIE apps, nimix-breaks).

Verified: `make test`, `test-arc`, `test-valgrind`, `test-asan` clean;
`test-devices` 7/7; `test-structured` 41/41; `test-qemu-models` 16/16 × 3.

## User-mode faults kill the task, not the machine (2026-10-26)

Human asked whether crashes halting the system follow from the joined address
space and the absence of OS threads. They do not. A ring-3 fault traps into
ring 0 on the task's own kernel stack with `cs & 3 == 3`; the kernel's state
is untouched, so the task can be ended exactly like `exit` (release region,
channels, caps, subscriptions; `procKill`; never resume it) whatever the
concurrency model. The shared address space weakens *isolation* (per-app CR3,
VISION open question 6), not *recovery*: only the running app's region is
user-accessible, so a stray user access faults instead of corrupting others.
Kernel-mode faults still halt — shared kernel state may be corrupt, and the
SASOS model's type-safe "apps" run in ring 0, so that is the honest policy.
WASM apps never reach this path (wasm3 traps are soft errors).

Mechanism: `kern/interrupts` exposes `userFaultKill` / `userStackBounds`
hooks (no dependency on the process table); `initSyscallGate` — where ring 3
becomes possible — installs `abiKillFaultingTask` / `abiCurrentTaskBounds`.
The user backtrace only follows frames inside the task's own region, so a
corrupt user rbp cannot make the kernel fault while reporting. Rejected:
installing the hooks from `wireSharedAbi` (drags the IDT asm into host tests
that import a model).

Found on the way: **`ExceptionContext` declared the 15 GPRs in reverse** of
`isr_common_stub`'s push order, so every register read from a trap frame was
another register (ctx.rbp was r9; kernel backtraces only worked by luck).
Fixed and pinned with compile-time `offsetOf` checks. Ring-3 spawn and the
sched/* copies were order-independent, so nothing else moved.
Apps now build with frame pointers; `fault.elf` (system tool) faults on
purpose; the Makefile's per-tool rules became one pattern rule (`NIM_TOOLS`).

Verified: `make test-devices` 10/10 (two user faults in one boot, shell alive,
region reused, frames symbolized to nullWrite/invalidOpcode via --app).

## Roadmap B, step 1: rasterizer, bitmap font, VT terminal, framebuffer console (2026-10-27)

**Boundary (reversible, logged for the human):** the drawing and terminal
code are *libraries* with no kernel imports — `gfx/` (canvas, UTF-8, bitmap
font), `term/` (VT model, incremental renderer), `input/` (evdev keymap) —
host-tested and usable unchanged by a userspace app_server / terminal app.
Their first consumer is a kernel **framebuffer console** (`kernel/console/`),
the fbcon equivalent: a basis prerequisite (see the principles: "some
prerequisites are allowed to enable the basis"), not GUI policy. The GUI
terminal *app* in a window comes with app_server (roadmap C) and reuses the
same libs; the kernel console can then become the fallback/boot console.

SURVEY:
- Font — adopted **Spleen 8x16** (BSD-2, Frederic Cambus; vendored BDF +
  licence; `tools/bdf2nim.py` → `gfx/font_spleen8x16.nim`, 351 glyphs:
  ASCII, Latin-1, box drawing). Rejected for the console: stb_truetype
  (needs libm + malloc + a TTF; stays vendored for userspace TTF later),
  font8x8 (too small at 1280x800), Terminus (OFL, no gain over Spleen),
  Unifont (huge).
- VT parser — built a subset on Paul Williams' DEC parser states. Rejected
  libvterm (~10k LOC, libc + malloc — far beyond a VT100 subset) and st's
  parser (entangled with X11). Fixed storage, no allocation.
- Rasterizer — built (clipped fill/rect/line/1-bpp blit/scroll, ~120 lines).
  raylib's software renderer stays the plan for apps (task 41) — it needs a
  platform layer and libc we don't have in-kernel.

Mechanism: `serial.putChar` gains a `consoleMirror` hook (core stays
dependency-free); output updates only the character grid; the shell's idle
loop (`consoleGetChar`, which also reads keys from the `input` topic via the
keymap) flushes at most every 2 ticks, presenting only the damaged rectangle
(`virtioGpuPresentRect`). Crash reports call `consoleFlushNow` so they are
visible on screen.

**Race found by the pixel test:** ring-3 apps write (and scroll) the grid
while the shell task renders it, so rows shifted under the renderer and
damage was lost (duplicated lines, gaps). The flush now copies the grid and
takes its damage with interrupts off (~190 KB memcpy) and renders the copy.

Verified: `make test-devices` 11/11 — the screen equals the serial byte
stream rendered on the host by the same code (`tools/term_replay.nim`),
pixel for pixel, with keyboard input and concurrent ring-3 output.

## Region capabilities: ownership + lifetime holes fixed (2026-10-27)

Human asked for big data to move formally, with no unsafe shared memory, and
asked us to *test* what exists. The region-capability "zero-copy" mechanism
was a sketch. A probe showed: (1) `abiGrantRegion` let any task mint a
write cap on any slot number; (2) owner exit freed the slot while caps still
named it, and the next app was given that memory (cross-app use-after-free);
(3) freed handles still read as valid, and exiting tasks leaked every cap
(including the spawn-time `ipcCap`). Fixed locally, with no API change:
the owner holds a reference from `regionAlloc`; a slot is recycled, and its
user window closed (`regionOnRelease`), only at the last reference; only
the owner or a `capMemGrant` holder may mint (`capMayGrantRegion`); exit
revokes all caps (`capRevokeAllOf`). Regressions in `tests/test_zerocopy.nim`.
Still open: rights are not enforced on access, and tokens are global. The
formal model (owned / move / lend / sealed buffers + typed rings, enforced by
page rights or the type system) is PROPOSED in docs/proposals/bulk_data.md.

## Bulk data FROZEN; buffers SPAWNED (2026-10-27)

Human agreed to all seven decisions of docs/proposals/bulk_data.md v2, which is
now FROZEN. The API is `ipc/buffers.nim` (a stub returning `beNotImplemented`;
layouts pinned by `tests/test_buffers_api.nim`), implemented by the new
sub-project `subprojects/buffers/`.
1. **The rule:** mutable memory is never shared. Owned or sealed; move/lend;
   rings are the only concurrent sharing. Two lanes: ≤240 B inline (copied),
   larger by buffer (moved or lent).
2. **Dispatcher-brokered sessions:** control messages and session setup go
   through the dispatcher, which forwards handles in `tmTransit` (no map
   right, never touches data). Steady-state streams flow on direct session
   rings under dispatcher policy (resize/reprioritise/revoke). VISION axiom
   clarified accordingly.
3. **Budgets follow ownership.** The requester provides the buffer by
   default; servers never allocate on a client's behalf.
4. **Enforcement:** Stage A = 2 MB blocks, ownership flipped in batches at
   `ringSubmit` and at context switch. Stage B = per-app CR3, the next kernel
   milestone. **Resolves VISION open question 6** (signal: app_server is the
   first service that must be protected from its clients); SASOS keeps the
   shared space and enforces by type.
5. **Per-task handle tables**, with handles carried out-of-band in messages
   (≤4) and translated by the kernel. Replaces global region tokens: an ABI
   change for `grantRegion` / `capSend` / fs replies, migrated by the
   sub-project.
6. **WASM:** copy at the sandbox edge (v1), region-backed aperture (v2).
7. **Arena:** 128 MB in 2 MB blocks (tunable constant).

Rejected (from v1 and the survey of the option space): direct app→server
transfers bypassing the dispatcher (violates axiom 1); a kernel call per
transfer (too costly for audio/frames/packets; batching instead);
server-allocated reply buffers (lets a client exhaust server memory);
global/guessable tokens (authority by number); free-form shared regions with
"protocol discipline" (the unsafe status quo the human ruled out).

## Buffers enforced from ring 3; four latent memory bugs fixed on the way (2026-11-03)

`subprojects/buffers` Stage A now runs in the kernel (`kernel/buffers/kbuffers.nim`).
- **Memory windows** (`mm/memory_windows.nim`): the app regions (32–96 MB)
  and a 64 × 2 MB buffer arena (from 96 MB) are reserved in the physical
  allocator and identity-mapped with 2 MB pages. The arena shrinks to the
  RAM that exists.
- **Enforcement:** arena blocks are supervisor-only by default. At every
  switch (`onTaskSwitch`), and after each buffer syscall, the PD entries are
  set to exactly what the running task may access (User for any access, RW
  only for write); only changed entries are rewritten and invalidated.
- **ABI:** 7 syscalls (30–36: `bufCreate/Map/Close/Seal/Return`,
  `bufMsgSend/Recv`). Handles ride channel messages out of band (≤4 per
  `ServerMsg`); a dropped message cancels its transfers (`onMsgDropped`).
- **Verified** (`make test-devices`, `buftest`): create/map/seal/close and a
  buffer moved through a channel arrive intact. Use-after-move, a write to a
  sealed buffer, and a write while lent each fault and kill only that task.

Latent bugs found and fixed (each predates buffers):
1. **Nothing reserved the app-region range** (32–96 MB) in the physical
   allocator: DMA allocations would have landed in app memory once they
   passed ~9 MB.
2. **Regions 8–15 (64–96 MB) were not mapped**; the boot stub maps only
   64 MB, so a 9th concurrent app could not start.
3. **`getOrCreateTable` walked into 2 MB huge pages as if they were page
   tables:** mapping any DMA page inside the boot identity map wrote a fake
   "PTE" into the kernel's early heap (`earlyArena`). Fix: a huge entry
   means already mapped; `kernelMapPage` maps one page without `mapRegion`'s
   `?`, because…
4. **core/types' `?` raises a Defect instead of propagating the error**, so
   every `?` in the kernel is a panic on its first error, and
   `mapOnePage`'s "already mapped is fine" branch could never run. It is
   contained here (`kernelMapPage`) and logged as a seam: making `?` return
   is cross-cutting.

Also: `initStore` built a 32 KB temporary on the 16 KB boot stack, which sits
right above the boot page tables, and zeroed them (the CPU ran on in its
TLB until the first miss). It now initialises in place, and kernel builds
fail on any stack frame over 8 KB (`-Werror=frame-larger-than=8192` in
nim.cfg; the current kernel has none).

## RUI2 vendored and surveyed; render-server model proposed (2026-11-03)

Human: RUI2 (`kobi2187/rui2`) is to be the foundational GUI toolkit; raylib
gets ported; WASM apps send draw commands to a native raylib render server
(server provides). VISION now states that model as the default and the
experiment, with exceptions as measured ADRs, plus end-to-end budgets.
- **Vendored** `vendor/rui2` as a git submodule @0038051 (like wasm3/printf).
- **SURVEY** (docs/surveys/rui2.md):
  - **Model:** immediate mode, with per-widget cached render textures
    → the server needs app-id'd render targets.
  - **raylib surface:** 84 calls, ≈ 25 draw ops; shaders only for 4 SDF
    primitives + the modal backdrop, which already fall back
    → semantic commands.
  - **Threads:** one UI thread + one background worker + a Mailbox, which
    map onto actors.
  - **Direct rlgl texture ids** → app-chosen resource ids.
  - **Build:** no WASM build yet; cyclic widget trees need ORC.
  - **Text:** all of it is Pango/Cairo and synchronous
    → measurement must be app-local.
- **Prior art adopted for the server:** raylib 6.0's `rlsw` software
  renderer, used GPU-less upstream (ESP32), behind a `PLATFORM_NIMIX`.
  Rejected: our own rasterizer (rlsw exists upstream); GLSL (no GPU);
  Pango in the app or server (synchronous, heavy).
- **Proposals PROPOSED** (awaiting agreement):
  - docs/proposals/render_server.md: the hybrid app_server, one server with
    two faces, rlsw, picolibc lean, TSC clock;
  - docs/proposals/draw_protocol.md: flat binary records, app-chosen ids,
    semantic SDF ops, text measured locally over shared sealed fonts with
    stb_truetype on both sides.
- **Budgets:** counts (commands/frame, kernel calls/frame, idle frames)
  gate CI on any accelerator. Times (key-to-pixel ≤ 33 ms p95, frame
  ≤ 16.7 ms) are judged under KVM and only tracked under TCG.
- Vertical-slice tasks V1–V11 are in BACKLOG.

## Text engine: Pixie (pure Nim) on both sides; HarfBuzz later (2026-11-03)

Human: RUI is theirs to modify; prefer a pure-Nim equivalent where binding
Pango/Cairo is impractical. Surveyed (docs/surveys/rui2.md addendum):
- **treeform/typography** is retired, merged into **Pixie**.
- **Pixie** (pure Nim, MIT, active) parses TTF/OTF from bytes, kerns
  (kern + GPOS), typesets spans with wrapping, and returns positions and
  selection rects. That covers RUI's measure / wrap / caret / hit-test
  API. Its SIMD is amd64-only, so wasm32 takes the scalar path.
- **elcritch/harfbuzzy** is wrappers over the system HarfBuzz (C++) +
  FriBidi, **not** pure Nim.

Decision (proposal-level, inside draw_protocol §5; the human leans this way):
- Pixie typesets in the app and rasterizes in the server, over the same
  sealed font bytes, so measured equals drawn by construction.
- RUI gets a text-backend seam (Pango | Pixie) upstream.
- stb_truetype is dropped from the plan: it would put C and libm into
  every WASM app.
- **Parked:** ligatures, complex shaping, BiDi. Resolving signal: the
  first RTL/complex-script user. The path then is harfbuzzy behind the
  same seam once HarfBuzz and FriBidi are ported; `TEXT_RUN` already
  carries shaped glyphs, so the protocol doesn't change.

## WASM is for isolation only; fast ops run natively (2026-11-03)

Human: "wasm was only required due to its isolation. All the ops that need
to be fast may run on servers or elf helpers." Recorded in VISION (decision
principles). Consequences:
- **Text:** Pixie runs natively, as host imports (`text_*`) granted by the
  app's **userspace ELF WASM host**, and in the render server. It is not
  compiled into WASM and interpreted by wasm3. Synchronous, native speed,
  no IPC; the app holds only handles; same code and font bytes on both
  sides (draw_protocol §5).
- **Prerequisite promoted into the slice:** move wasm3 out of the kernel
  into a per-app userspace ELF host (BACKLOG V8). Native helpers must never
  run in the kernel.
- **Two native venues:** coarse/shared work goes to servers (render,
  decode, files); fine-grained synchronous work goes to ELF helpers (host
  imports). If the app's own code misses its budget under the interpreter,
  the exception is AOT that keeps WASM's isolation (wasm2c, RLBox-style;
  BACKLOG V12, parked until V9 measures).
- Rejected: running RUI's framework natively with app callbacks crossing
  into WASM. Closures and refs would cross the sandbox boundary on every
  handler; only leaf operations with plain-data arguments become imports.

## Kernel residency is historical, not design (2026-11-03)

Human: "if something runs in the kernel, it's only because the os started
with kernel decisions and kernel was all we had, so over time, these move to
their proper place. if it's not inherent and part of the design, then we
find where each component should reside." Recorded in VISION (decision
principles). Made concrete as the **residency map** in ARCHITECTURE.md:
- every kernel-resident component, classified as inherent (privilege or
  universal trust: scheduling, memory, interrupts, caps, IPC transport,
  buffer enforcement, crash output) or historical;
- for each historical one, its proper home and the blocker.

**Historical:** wasm3, the shell, the fb console/VT, all device drivers
(gpu, snd, input, net, blk, PS/2, RTC), VFS/FatFs, the ping/dispatch kmods,
the event topic registry.

The common blocker is **R0, device capabilities** (IRQ subscription, MMIO,
DMA buffers, PCI config): VISION open question 4's prerequisite, which
buffers (DMA-able, owned memory) now makes tractable. Migrations R0–R10
are in BACKLOG, ordered to coincide with the vertical slice: the render
server takes the GPU (R2/V6), the audio server takes snd (R4/V10), and the
WASM host leaves the kernel (R1/V8).

The kernel *model* still decides where a component runs: monolithic may
link a server in, by design. What changes is that no component is *forced*
into the kernel for every model.

## The raylib bridge: apps don't change; route decided per op (2026-11-03)

Human: commands-to-a-render-server means every RUI app must change; put a
bridge layer in between that decides whether to forward an operation to
raylib or create a command from it. Added to draw_protocol §7 (proposal):
- **The bridge** is a naylib-compatible `raylib`/`rlgl` module pair, so
  RUI and stock raylib programs compile against it unchanged.
- **Routing by class:** draw ops are routed per op; CPU image ops are
  always local; queries are answered locally from session state; window and
  input go to app_server when remote.
- **Backends:**
  - `direct`: inline forwards to in-process raylib, zero cost;
  - `remote`: commands; the only backend in WASM;
  - `hybrid`: per-op routing from server feature bits, encodability and
    policy, with counted local fallback through an uploaded texture.
- **Per-window switching** between remote and direct is VISION's exception
  mechanism, decided by policy rather than by rewriting the app.

Rejected: a pure command shim (forces every app onto one path and leaves
no fallback for ops the server lacks); changing RUI's call sites (RUI is
one of many raylib clients the bridge should serve).

## Render-server model + raylib bridge AGREED; P0 host prototype first (2026-11-03)

Human agreed ("let's do that") to the render-server model with the raylib
bridge, noting the possible performance penalty and the amount of support
work.
- **Status:** render_server.md is AGREED; draw_protocol.md is agreed in
  principle. The record set is frozen at V6 spawn, after P0 validates it.
- **Performance answered early, not at V9:** P0 is a host-only loopback
  prototype. The same screen goes through the bridge `direct` (raylib
  in-process) and `remote` (encode → decode → raylib) paths in one
  process. Equal pixels are the protocol conformance test; frame time and
  records/frame give the model's cost before any kernel work.
- **Pin raylib 6.2**, the latest release; `rlsw` and the `rcore_memory`
  headless platform are both present since 6.0.
- naylib master bundles raylib 5.6-dev (no rlsw, no memory platform), and
  RUI pins an older naylib. So **the bridge is our own naylib-compatible
  binding to raylib 6.2**, not a layer over naylib, and it absorbs the
  5.x → 6.x API differences.
- `rcore_memory.c` is also the template for `PLATFORM_NIMIX` (memory
  platform + damage blit to virtio-gpu).

## P0 result: the command path costs ~nothing; rasterization is the cost (2026-11-03)

`make test-p0` (host only, tests/p0): one RUI-shaped screen (each widget
cached in its own render target, parents composite, one widget changes per
steady frame), built twice from the same source against the raylib bridge
(`bridge/`). The direct build is in-process raylib 6.2 + rlsw, headless
(`rcore_memory`). The remote build encodes commands → loopback render
server → the same raylib.
- **Conformance:** remote pixels are **byte-identical** to direct (82,815
  painted pixels at 640×400).
- **Command budget:**
  - steady frame: **19 records, 424 B** (budget ≤ 200 / 16 KB; design
    estimate ~15 / 0.6 KB);
  - full repaint: 88 records, 2.2 KB.
- **Model cost:** encoding < 1 µs per frame. Over 3 × 200 steady frames,
  direct was 9.8–10.4 ms and remote 10.3–11.6 ms, a **~0.5–1 ms (~7%)
  difference inside run-to-run noise**. Not yet included: the IPC hop (one
  `ringSubmit` + a switch), measured on NimixOS in V9.
- **The real cost is rlsw raster time (~10 ms at 640×400 on this host):**
  RUI's steady frame recomposites the whole root and blits it full-screen.
  The lever is **damage-limited compositing** (scissor to the dirty rect;
  present only damage). That is a renderer change, not a protocol change.
  Recorded as the first optimisation for the render server (V6).
- **The bridge is our own naylib-compatible binding to raylib 6.2**
  (`rl_types`, `rl_c`, `rl_direct`, `rl_remote`, `rl_server`,
  `rl_protocol`). Direct = inline forwards; the server validates record
  lengths and session ids and stops a malformed frame.
- **Known for V5:** rlsw's colour buffer is R8G8B8A8, but the
  `LoadImageFromScreen` readback is vertically flipped with R/B swapped
  (it assumes GL's origin). `PLATFORM_NIMIX` blits from `swGetColorBuffer`
  directly, with a pixel test to pin orientation.

## V7a: RUI on the bridge, direct, via adapted naylib + a Pixie text engine (2026-11-03)

RUI's counter example builds **unchanged** and paints headless through the
raylib bridge's direct backend (`make test-v7`): raylib 6.2 memory platform
+ rlsw, Pixie text.

- **Bridge base = adapted naylib, not hand-written** (SURVEY: RUI re-exports
  naylib's whole type/enum surface, ~4,000 lines with RAII destructors RUI
  relies on). naylib v25.51.1 (pinned submodule, `vendor/naylib`) binds
  raylib 5.6-dev and hard-wires a GLFW build, so **adapt**, reproducibly:
  `tools/naylib_adapt.py` generates `build/bridge/naylib/` with (1) the
  build header replaced by raylib 6.2 from `vendor/raylib` (memory
  platform, rlsw, no GLFW/utils/raudio), (2) naylib's 5.x config `-D` flags
  dropped so 6.2's `config.h` applies, (3) the 6.2 ABI fixes
  (`DrawCircleGradient`, `ImageColorContrast`, `ImageDrawRectangleLines`,
  `UpdateModelAnimation`, `DrawCapsule(Wires)`), (4) naylib's Win32-clash
  renames back to upstream symbols (`rlRectangle`, `rlCloseWindow`,
  `rlDrawText`, ...). Each patch must match exactly once or the script
  fails, so a naylib bump surfaces drift instead of hiding it. Rejected:
  forking naylib (a second repo to keep in sync); hand-writing the 84-call
  surface (RUI uses the full types, not just the calls).
- **rlsw caps raised** to 512 framebuffers / 2048 textures (defaults 8/128):
  RUI keeps a render target per widget. Pools are heap handle tables, so
  the cost is small; the render server will want a per-session budget.
- **RUI changes ride as a patch set** (`patches/rui2/`, applied by the test
  runner) until they land upstream (V11): the text-engine seam
  (`text_engine` → Pango | Pixie, `pango_text` keeps its API and caches),
  the Pixie engine, and `-d:ruiNoGlfw` (RUI's two direct GLFW uses: idle
  wait sleeps, mouse-button hooks fall back to raylib polling). The Pango
  path still type-checks.
- **Upstream raylib 6.2 bug found:** `rlReadScreenPixels` flips rows for
  GL's bottom-left origin, but rlsw's `swReadPixels` already returns them
  top-down, so `LoadImageFromScreen` is upside down under rlsw (this also
  hits RUI's modal freeze). Our test unflips; the fix (skip the flip for
  `GRAPHICS_API_OPENGL_SOFTWARE`) goes upstream with V5.
- **Next (V7b): route at the C-symbol level.** The adapter can emit a
  remote variant whose routed procs `importc` our encoders (`exportc`)
  instead of raylib, leaving types, CPU image ops and queries as naylib.
  The routing table is then the hybrid mechanism, and apps still don't
  change.

## V7b: remote bridge by C-symbol routing; RUI remote == direct (2026-11-03)

RUI's counter example, unchanged, clicked three times through RUI's own
event router, renders **byte-identically** through the remote bridge (draw
calls → command records → loopback render server → raylib) and the direct
one, repeatably (`make test-v7`). Steady frames: at most **86 records /
1,016 B** (budget 200 / 16 KB); the first full paint 121 / 1.6 KB, plus
63 KB of glyph textures uploaded as blobs over the run.

- **Route at the C symbol, not the Nim proc.** The adapter emits a second
  naylib (`build/bridge/naylib_remote/`) where each proc whose C symbol has
  an `nxr_<Name>` in `bridge/rl_route.nim` imports that instead. Encoders
  are `exportc` with raylib's C ABI and P0's C-layout types, so there is no
  import cycle with naylib. The routed names come from rl_route itself and
  each must match exactly once, so the table can't drift. naylib's
  destructors, wrappers and every call site route with no Nim changes.
  Rejected: re-declaring naylib's API by hand (the 4,000-line surface again);
  a per-function generator from headers (the interesting cases, ids and
  syncs, are semantic anyway). This is also the **hybrid** mechanism: a
  routing table per symbol.
- **Headers:** naylib pushes `header: "raylib.h"` onto its procs, so the
  remote variant pushes a generated `nimix_route.h` instead (raylib.h +
  rlgl.h + the `nxr_` prototypes copied from 6.2's own declarations).
- **One record per raylib call**, executed server-side by the same function:
  that is what makes pixels identical (e.g. `DrawRectangleLines(int)` and
  `DrawRectangleLinesEx` rasterize differently). The record set is still
  frozen only at V6.
- **Ids:** app-chosen; a render target's id also names its colour texture.
  Destroys are idempotent (RUI frees a target's texture, then the target).
- **Refused locally, by design:** raw rlgl framebuffers (`rlLoadFramebuffer`
  → 0, so RUI takes its own `loadRenderTexture` path) and shaders (invalid,
  exactly as on rlsw, so RUI uses its non-shader fallback). No raw GPU
  objects cross the boundary.
- **Uploads ride as blobs** beside the stream (the loopback stand-in for
  moved/sealed buffers); `LoadImageFromScreen` is a counted **sync point**
  (NimixOS: a SNAPSHOT command, no readback).
- **Hardening:** every decoder read is bounded by its record; a short record
  fails the stream (P0's decoder could read past a record before).
- **Determinism note:** RUI's hover fades are time-based, so captures wait
  for them to settle; direct differed from itself mid-fade.
- **Observed for V6/RUI:** a label change costs ~63 records, because RUI
  recomposites up the tree to the root. Within budget; damage-limited
  compositing (P0 finding) also shrinks this.

## GPU acceleration parked (2026-11-03)

Asked whether to use QEMU's accelerated GL. Survey: QEMU 8.2 in this
environment has `virtio-gpu-gl` (virgl, virglrenderer 1.8.8); Venus (Vulkan),
gfxstream and DRM native context need QEMU ≥ 9.2, and DRM native context
also a host GPU. Every option's guest side normally means Mesa or a Linux
DRM driver. The fitting design, if needed: a small rlgl backend that speaks
virgl's command stream for raylib's GL subset, inside the render server
only (the bridge and the server-provides model keep apps, RUI and the
protocol unchanged). **Parked** (human: "can do a lot without it"; VISION
Q7, BACKLOG V13). Signal: V9 shows the server missing its frame budget
after damage-limited compositing. rlsw stays the floor and the pixel-exact
test reference (GPU output is not bit-identical across hosts; this
container has no host GPU, so virgl would run on llvmpipe).

## V3: fine clock = TSC calibrated against PIT channel 2 (2026-11-08)

**Survey.** Prior art: Linux's `pit_calibrate_tsc` / `quick_pit_calibrate`
(PIT ch 2 one-shot polled through port 0x61 bit 5), the clocksource
mult/shift form, vDSO/pvclock (apps read a kernel-published page and use
their own rdtsc), CPUID leaf 0x15 (no help under TCG), HPET/ACPI PM timer
(more hardware, nothing the PIT gate doesn't already give for this target).
**Adopt the technique, build the code** (it is ~100 lines; owning it is
cheaper than a dependency).

- **Pure math apart from the driver:** `core/tsc_clock.nim` (mult/shift,
  rounded multiplier, two-half 64×32 product, exact for any delta while the
  result fits 64 bits) is host-tested against an exact `__int128`
  reference: ~1 ppb at ≤ 10 GHz, 1 MHz..100 GHz accepted, monotonic,
  clamped before base. `drivers/tsc.nim` is only ports + rdtsc + the global.
- **Calibration:** median of five 30 ms PIT-ch2 windows. Observed under
  QEMU TCG: 2300 MHz, windows spread 0.03–0.1 % (host scheduling jitter in
  the poll loop), so the median, and a longer window than the first try
  (3 × 20 ms spread 0.16 %). Interrupts are off; channel 2 doesn't touch the
  100 Hz tick on channel 0.
- **Evidence (the independent cross-check):** `make test-structured` sleeps
  100 PIT channel-0 ticks and compares with the TSC: 999–1000 ms vs 999 ms
  expected over five boots (gate: 1 %). An earlier version of this test
  failed (988 ms) and the cause was the test, not the clock: a sleep "until
  the tick count reaches N" ends on a tick edge, so starting mid-tick
  measures 99–100 periods. The test now starts on an edge.
- **Assumption (QEMU only, per VISION):** invariant TSC. TCG derives TSC and
  PIT from the same virtual clock. A hardware port would check CPUID
  0x80000007 and fall back to the PIT.
- **Not decided: exposure to apps (V3b, cross-cutting ABI).** The BACKLOG
  said "`nanoTime` syscall". VISION's budget is ~1 kernel call per frame and
  raylib's `GetTime()` runs every frame, so a syscall per read is the wrong
  shape. Options: (A) syscall; (B) a read-only time page (base, mul, shift,
  hz, valid), mapped into every task, read with the app's own rdtsc and the
  same `clockNanos`: zero kernel calls, consistent with "kernel-written,
  user read-only, never mutable-shared" (written once at boot); (C) B with A
  as the fallback when `valid` is false. **My pick: C.** Open: where the page
  lives (a fixed read-only user mapping in each app window vs a sealed
  buffer lent at spawn). Waiting for the human.

## V2: picolibc is the libc/libm for server and app ELFs (2026-11-09)

Human: "Allow picolibc, can be trusted. I assume musl is heavier? If so pick
picolibc." (Yes: musl is a complete Linux-syscall libc; its pieces would be
extracted and its syscall layer replaced, picolibc is built for exactly this.)

**Survey** (what raylib 6.2 + rlsw need): compiled against glibc's headers
the objects leave 110 symbols undefined: ~18 fortify/stack-protector (the
distro compiler's defaults; gone with `-U_FORTIFY_SOURCE
-fno-stack-protector`), ~26 math, ~30 file/OS, the rest plain libc. Options:
- **picolibc** (BSD-3, newlib-derived, tinystdio, libm from fdlibm and ARM
  optimized-routines; designed for freestanding targets that supply a few
  hooks) — **adopted**.
- musl — rejected: heavier, built around Linux syscalls.
- our own libc — rejected: `printf`/`scanf`/`strtod` and a libm are the
  parts that are expensive to get right, and a mature one exists.

**Result** (`make test-v2`, CI too):
- picolibc builds from the pinned submodule in ~10 s with `tools/picolibc_build.sh`
  (freestanding x86-64, PIC, no red zone, no stack protector, no TLS,
  global errno, no math errno, no threads).
- Compiled against **picolibc's own headers** (`-nostdinc`; glibc's headers
  have a different `FILE`, `errno` and locale), raylib + rlsw link needing
  **exactly 31** symbols from the OS, pinned in `tests/v2/expected_os_symbols.txt`
  so a raylib bump that starts needing something new fails the test:
  `_exit`, `open/close/read/write/lseek`, `stdin/stdout/stderr`, the
  directory and file calls (`stat access opendir readdir closedir getcwd chdir
  mkdir rename unlink readlink`), `clock_gettime gettimeofday nanosleep`, the
  heap bounds `__heap_start/__heap_end`, and refusing stubs for
  `fork execve waitpid fcntl tcgetattr tcsetattr`. Everything else (string,
  malloc, qsort, printf/scanf/strtod, the whole libm) is inside picolibc.
- picolibc's libm is within **1 ULP** (0 for sqrt/fmod) against correctly
  rounded references over 7,600 samples, run natively. raylib draws with
  these functions, so an inaccurate one would show as subtle pixel
  differences between machines and render paths.
- A first run of the libm test failed on `sincosf` for every sample, and the
  cause was the test: without `_GNU_SOURCE` the function isn't declared, C
  then passed the `float` as a `double`. The test now compiles with
  `-D_GNU_SOURCE -Werror=implicit-function-declaration`.

**Next, V2b ("libnimix"):** the OS layer implementing those 31 symbols over
the Nimix ABI: fs through fs_server, time from the time page (V3b), sleep
through `nimixSleep`, heap bounds from V4. It is the seam where "POSIX-shaped
C" meets "capability OS", so it is also the natural place to teach how the
two differ.

## V3b: the clock reaches apps through a read-only time page (2026-11-09)

Human: "whatever is more lightweight and efficient." Built as option C of
§V3 minus the syscall (see below).

- **The page:** `TimePage` (`core/tsc_clock.nim`), 40 bytes, magic `"NIMIXTIM"`,
  version, valid, base, hz, mul, shift. Layout pinned offset by offset in
  `tests/test_tsc_clock.nim`. It lives at 224 MB (`TimePageAddr`, checked at
  compile time to be `ArenaBase + ArenaSize`) in **its own 2 MB window**:
  rights are per huge page, so sharing a window with anything else would open
  that to ring 3. The kernel writes it once at boot (before any task runs,
  supervisor-only), then `publishTimePage` maps it **user read-only** for
  every task. Because nothing writes it afterwards, readers need no lock; if
  recalibration is ever added, add a sequence counter first (noted in the
  source).
- **Apps:** `apps/nim/nimix_time.nim` `nanoTime()` = the app's own `rdtsc` +
  the same `clockNanos` the kernel uses (tested equal for every frequency).
  Zero kernel entries per read, which is what raylib's per-frame `GetTime()`
  needs against VISION's ~1 kernel call per frame.
- **Evidence (QEMU, `make test-devices`):** a ring-3 `clocktest` measures
  3 s of PIT ticks as 2998 ms (+-1 % gate); writing the page raises #PF in user
  mode and kills only that task; the shell survives.
- **Fallback without a new syscall:** if the page isn't valid (PIT dead at
  boot), `nanoTime()` returns `nimixUptimeSecs()` seconds. This replaces the
  "`nimixNanoTime` syscall as fallback" of §V3: the path never runs on the
  QEMU target, and a new syscall number costs six tables (enum, symbols,
  dispatch, vtable, header, stub) for code that would never execute.
- **The window is mandatory:** apps read the page without asking, so a VM too
  small for it (under 226 MB) now fails at boot (`initMemoryWindows`), as the
  other windows do, instead of faulting in every app. The default VM is 256 MB.
- **Not measured:** the `clocktest` read cost printed under QEMU TCG
  (~1.8 µs) is TCG's emulated `rdtsc`, not the design's cost; on KVM or real
  hardware `rdtsc` is tens of cycles, but that is an expectation, not a
  measurement. V9's benchmark should measure it on KVM.
- **Why this is the sealed idea in a fixed place:** the buffers model allows
  sharing immutable data and forbids sharing mutable data. The time page is
  immutable after boot; a fixed address (instead of a lent buffer handle)
  because every task needs it and a handle would add a call per task.

## V2b: libnimix — C programs run on NimixOS (2026-11-09)

Goal: the 31 OS-layer symbols of §V2, implemented over the Nimix ABI, so raylib
and any C code run here. **Done:** `libctest` (a plain C program: printf with
floats, sscanf, strtod, qsort, 8 MB of malloc/realloc, libm, nanosleep, a real
date, files written and read back on the FAT disk, directory listing,
refusals, arguments) passes 42 checks under QEMU; raylib + rlsw + picolibc +
libnimix link with nothing unresolved (the golden "31 symbols" file became
"zero").

Design choices (each with what was rejected):
- **C, compiled against picolibc's headers**, not Nim: the consumers are C and
  must agree with picolibc's `FILE`, `DIR`, `struct stat`; re-declaring those in
  Nim would be a second copy to drift. Rejected: Nim `exportc` shims.
- **Heap = one owned arena buffer** created on the first `sbrk` (V4 in use). 16 MB
  default (`-DNIMIX_HEAP_BYTES` to change), inside the 32 MB task budget.
  Rejected: a static `.bss` heap (the app slot is 4 MB).
- **Clock without a syscall:** `clock_gettime` reads the time page (V3b) with the
  program's `rdtsc`; the C reader is bit-identical to the Nim one (63 shared
  golden vectors, regenerated from `core/tsc_clock.nim`).
- **`nanosleep` never returns early but can be one tick (10 ms) late:** sleeps
  all but the last two ticks, then yields until the moment. Precise waking
  needs a one-shot timer (LAPIC/TSC-deadline): parked (V2c). Measured: 250 ms
  requested, 260–265 ms observed.
- **Files: a whole-file model over the VFS ABI** (read all on open, write back
  on close). The ABI is path-based and whole-file because that is what the
  in-kernel VFS exposes: ambient authority, flagged in the source and README as
  an interim seam. It is also what a lent-buffer `fs_server` will look like to a
  program, so program-facing code survives the swap (V2c).
- **Refusals are design:** `fork/execve/waitpid` (programs are started by the
  dispatcher with capabilities), `tcgetattr/tcsetattr` (no controlling
  terminal), `fcntl` (no inherited descriptors), `mkdir/rename/unlink/readlink`
  (no ABI calls yet) return -1 with an errno and a stated reason.

Two real bugs this work exposed, both fixed:
1. **The ring-3 entry stack was 8 bytes misaligned.** The SysV ABI enters a
   function with `rsp ≡ 8 (mod 16)`; `procSpawnRing3` set `rsp` to the
   16-aligned top, so aligned SSE stack stores (`movaps` in `printf`) raised
   #GP (found by symbolizing the fault: `vfprintf`, `movaps %xmm0,-0x80(%rbp)`).
   Nim apps never use aligned SSE stack stores, so it stayed hidden since
   ring 3 was first brought up. Now `entryRsp = (top & ~15) - 8` with a zero
   return address (a stray return from `appMain` faults at 0). `libctest` has
   a regression check.
2. **`nimixFsRead` could not say "buffer too small".** The FAT driver returned
   `fTooBig` and the VFS wrapper flattened it to -1, the same as "not found", so
   a C `fopen` of a 260 KB file looked like ENOENT. Contract now: **-2** means
   the file exists but is larger than `len` (retry with more room), -1 any
   other failure; documented in `nimix_abi.h`.

Also: `kernel/abi/nimix_abi_stub.c` held two things, the weak syscall stubs and a
mini-libc for Nim's standalone runtime (`malloc`, `memcpy`, `fprintf`...), which
collides with picolibc. The ABI half moved to `nimix_abi_weak.c` (built
without optimisation: at -O0 even empty stubs are ≥ 16 bytes, which the loader's
16-byte trampoline needs); the Nim stub object still includes it unchanged.
Building the disk image (`disk-add-apps`) now builds C apps, so it needs
meson + ninja (`apt install meson ninja-build`).

## The kernel must not touch FPU/SSE state; new tasks start clean (2026-11-09)

**Symptom:** CI failed `libctest: FAIL sinf` on the runner, once, while the same
binary passed locally every time (1 check of 42, wrong value of a pure
function). Not loosened: a wrong float from a deterministic function is a
corrupted register until proven otherwise.

**Cause (two kernel bugs, found by making the failure deterministic):**
1. **The kernel clobbered the program's xmm registers on every timer tick.**
   The kernel was built without `-mgeneral-regs-only`, so its C code used SSE
   (`objdump` of the kernel: ~1,380 SSE/x87 instructions). Interrupt entry
   saves only the general registers, and `fxsave` happens later, only when the
   handler decides to switch tasks. A tick landing in a user float computation
   left the kernel's values in `xmm0` when the program resumed. Rare (needs a
   tick inside a window where a value is live in an xmm register), so it hid:
   Nim apps seldom hold floats across many instructions; C code with libm does.
2. **A new task inherited the previous task's FPU/SSE state.** `claimSlot` zeroed
   the task and `fpuValid=false` made the first switch-in skip `fxrstor`: a leak
   of one task's registers into the next, and nondeterministic start state.

**Test first** (`fputest`, `make test-devices`): load all 16 xmm registers and
the x87 stack, spin ~8 timer ticks in pure assembly, compare. On the unchanged
kernel it failed deterministically ("xmm0 changed"; "new task does not start
with cleared SSE registers"), which turned a one-in-forty flake into a
reproducible failure.

**Fix:**
- `-mgeneral-regs-only` in `nim.cfg` (kernel only): kernel code can never touch
  x87/SSE state, as in Linux (which builds with `-mno-sse -mno-mmx
  -msoft-float`). That makes "save FPU state only on task switch" correct.
  Verified on the binary: 0 SSE/x87 instructions in all three kernel models
  (was ~1,380). The kernel uses no floating point, so nothing else changed.
- `claimSlot` gives every task the System V default FPU image (FCW 0x037F,
  MXCSR 0x1F80, MXCSR_MASK 0xFFFF) and `fpuValid = true`, so the first switch-in
  restores a clean state.

**Rejected:** saving FPU state on every interrupt entry (fxsave ≈ 512 bytes of
stores per tick, per IRQ, to defend against code we control); loosening the
`sinf` tolerance (would have hidden it); retrying the CI job (would have hidden
it).

**What it says about the design:** the user/kernel boundary includes *register
state*, not only memory. A capability OS that isolates pages but lets a timer
tick rewrite a program's registers has not isolated the program. The same
reasoning applies to anything the kernel does on a task's behalf: it may use
only what it saves.

## A failing host test could not fail the build (2026-11-09)

**Found by accident.** While adding two syscalls I touched files that
`tests/test_syscall_table.nim` depends on, which forced Nim to recompile it, and
it failed: `no weak stub in nimix_abi_stub.c for nimixWrite`. It had been failing
since V2b moved the weak ABI stubs to `nimix_abi_weak.c`, i.e. for a whole
milestone. `make test` exited 0 and printed "All tests passed"; the PR's CI,
which compiles from a clean checkout, showed the stack trace in its log and
stayed green.

**Two separate faults:**
1. **The test binary exits 0 after an unhandled `AssertionDefect`** (it prints
   `Error: unhandled exception ...` and `main` returns 0; verified with gdb and
   strace: `exit_group(0)` from `__libc_start_call_main`). A minimal program with
   the same flags and imports exits 1 as it should, so something about this
   test's run state turns the failure into success. **The cause is not found**;
   I did not keep digging because the guarantee does not need it.
2. **A stale binary hid the failure locally.** The test reads C files with
   `staticRead`, which Nim's incremental build does not track, so changing those
   files did not recompile it and the old passing binary ran again.

**Fix (the guarantee, not the cause):** `tools/check_run.sh` runs every host
test and fails on a non-zero exit **or** on Nim's `Error: unhandled exception`
marker, whatever the exit code says. All three host-test loops (plain, valgrind,
ASan), `test-arc` and the CPS run go through it. With it in place the whole host
suite was run: `test_syscall_table` was the only hidden failure.
`test_syscall_table` now reads both stub files and again checks something.

**Rejected:** just fixing the one test (leaves every other test one refactor
away from the same silent failure); retrying until it fails (it is
deterministic once it recompiles).

**Open, cheap to close later:** why that binary returns 0 (the output-based
guard works, but an exit code that lies is a trap for the next person), and
whether `staticRead`-based tests should force a rebuild.

## V5a: display ABI v1 (2026-11-09)

Proposal `docs/proposals/display_abi.md`; my pick was built (human: "go
according to your picks"; the ABI is two calls, so redirecting is cheap).
**Option A:** the program renders into a buffer it owns and calls
`nimixDisplayPresent`; the kernel validates, copies the rectangle to the
scanout and flushes it. Rejected for now: mapping the scanout into the program
(needs device capabilities R0/R2 and lets a program write memory the GPU reads),
and a write-style stream. The calls survive the later move: `Present` takes a
buffer handle today and a lent surface or compositor target tomorrow.

Built: `nimixDisplayInfo` (width, height, format B8G8R8X8, stride) and
`nimixDisplayPresent` (handle, stride, source rect, destination). Ownership is
implicit: the first successful present owns the screen, the kernel console stops
painting (its grid keeps filling), a second task gets -2, and exit/kill/fault
releases it and repaints the console (`displayRelease` in task cleanup).

**Every access is checked, and the checks are host-tested** (`display_checks`):
rectangles against the buffer's size and stride and the display, all in 64-bit
arithmetic so no 32-bit values can wrap into a valid-looking request; the
buffer is read only through the buffers store (`kbufReadable`: a buffer moved or
lent away cannot be shown); the request struct is copied once (no checking a
value that can change); and **its address must lie in the caller's own region or
the buffer arena**. Today no other syscall validates user pointers (the
shared address space makes that a confused-deputy risk); that wider gap is
recorded as a seam, and these two calls do not add to it, since `Info` writes
through a user pointer.

**Test:** `gfxtest` (C, ring 3) first makes ten bad requests that must each be
refused and must not take ownership (zero width, a row past the buffer, a
narrow stride, off the display, a negative destination, a handle it does not
hold, a short struct, NULL, a pointer into the kernel for the request and for
the info output), then presents; the harness's QMP screendump of the virtio-gpu
region equals the pattern recomputed on the host for all 256,000 pixels.

**A race, found by that test (nondeterministic at first: our frame showed in
some runs and the console in others):** the console's flush runs in the shell
task and can be preempted half-way through painting. A program that took the
display then drew its frame, and the shell resumed and painted console pixels on
top of it. `gSuspended` was only checked at the start of a flush. Fix: a
handshake. A flush sets `gInFlush` BEFORE it checks `gSuspended` (so there is no
window in which the new owner sees "no flush running"), and taking ownership
waits, yielding, for `gInFlush` to clear, bounded to 50 ticks so a flusher that
died mid-paint cannot hang the display. 6 of 6 runs after the fix. This is the
same family as the console race the original pixel test found: two writers to
one framebuffer need an ownership protocol, not just a flag.

## V5b: raylib 6.2 runs on NimixOS (2026-11-09)

A ring-3 C program (`apps/c/rldemo`) draws with plain raylib calls (shapes,
gradient, rounded rectangle, ring, text) on rlsw and presents through the display
ABI. **Done-check met:** the QMP screendump of the virtio-gpu equals the host
render of the same scene, all 256,000 pixels, and four real colours are asserted
independently of the comparison.

- **PLATFORM_NIMIX by a generated overlay, not a vendored copy.** raylib picks
  its platform with `#include "platforms/rcore_memory.c"`, and a quoted include
  looks in the including file's directory first, so nothing outside can replace it.
  `tools/raylib_nimix.py` builds `build/raylib-nimix/src` as symlinks to the
  pinned tree plus one generated file: the memory platform with 9 substitutions,
  **each of which must match exactly once**, so a raylib bump that moves the text
  fails loudly (the same discipline as `naylib_adapt.py`). Rejected: copying the
  file into the repo (a second copy of third-party code to keep in sync), and
  `ld --wrap` (the call is inside one translation unit).
- **What changed vs the memory platform:** the framebuffer is an *owned arena
  buffer* (a task can only present memory it owns); `SwapScreenBuffer` presents
  through `nimixDisplayPresent` (one kernel call per frame); `SetWindowPosition`
  places the window; the termios/`getchar` input polling is gone.
- **An upstream quirk found, and pinned:** in raylib 6.2 a
  `PIXELFORMAT_UNCOMPRESSED_R8G8B8A8` readback from rlsw delivers the bytes
  **B, G, R, A** (SKYBLUE, R=102 G=191 B=255, reads back as 255 191 102 255; the
  same quirk as the `LoadImageFromScreen` note in §V7a). By luck that is exactly
  the display's native B8G8R8X8, so the bytes go straight through with no
  conversion. My first version swizzled R/B "correctly" and produced wrong
  colours; the host reference writer had to learn the quirk too. The test
  `raylib-colours` asserts real colours on screen (SKYBLUE, GREEN, MAROON,
  RAYWHITE), independent of the pixel comparison, so if upstream fixes the
  readback this **fails loudly** instead of silently swapping red and blue.
- **Exact equality held** although the host used glibc's libm and NimixOS uses
  picolibc's (≤ 1 ULP apart): this scene lands on no rounding boundary. A scene
  that did would differ by a pixel, which would be a finding about the libm
  difference, not noise to be thresholded away.
- **Program images:** the first build was 1.1 MB and the shell answered
  "Unknown command" because it reads programs into a fixed **512 KB** buffer
  (`diskFileBuf`), a misleading message for "too big". Linking with
  `--gc-sections` (code compiled with `-ffunction-sections`) and `--strip-debug`
  (picolibc's objects carry DWARF) gives **248 KB** (libctest 260 to 66 KB) and
  keeps the symbol table the loader needs for `appMain` and the ABI stubs. The
  512 KB limit and its error message are a seam (V5d).
- **A scene bug of my own:** the first demo had no triangle. raylib's
  `DrawTriangle` wants counter-clockwise vertices and culls the other winding. I
  only saw it because I looked at the host render before trusting the comparison.
- **Not yet:** damage (a full frame is converted and copied per `EndDrawing`: raylib
  tracks no damage, the V6 render server will know it from the command stream);
  input (V5c: evdev events on the `input` topic into raylib's key state); the
  display is not cleared on taking ownership (the console's old pixels show around
  a window smaller than the screen).

## V5c: keyboard input into raylib (2026-11-10)

`rlkeys` (a raylib program): D/A and the arrow keys move a square, typed characters
are collected, Q quits. The test injects real key events through QEMU's virtio
keyboard and checks three things: the square moves on the screen (pixels), the
program received exactly the key sequence D D D Right Left Left Q and the characters
`ddd`, and the shell received none of it.

- **Input follows display ownership.** The shell does not wait for a foreground
  program, and the event bus delivers a copy of every key to every subscriber, so
  typing into a raylib program would also have typed into the shell's command line
  (executed on exit as "Unknown command"). While a program owns the display
  (`consoleInputGrab`, set and cleared with the display ownership) the console still
  drains its key queue, so it cannot fill, but acts on nothing, and resets its
  modifier state at each hand-over so a held shift cannot stick. This is a first,
  deliberately simple "focus": the display owner gets the keys. A real focus model
  arrives with windows (V6).
- **Two keymaps, one authority.** The platform needs evdev to raylib `KeyboardKey`
  values and to characters, in C. `input/evdev_keymap.nim` stays the authority for
  characters: `gen_key_vectors.nim` writes 1,024 vectors (128 codes x 8
  shift/caps/ctrl combinations), and both the Nim test and the C test
  (`tests/libnimix/test_keymap.c`) must reproduce them, so neither can drift. The
  C test also includes `raylib.h` and checks all 81 mapped keys against raylib 6.2's
  own enum, so a renumbering upstream fails there. Same technique as the clock.
- **Two input bugs, found by watching the data and not by guessing:**
  1. **Taps.** A tap delivers press and release together. If both land in one frame,
     raylib's edge-based `IsKeyPressed` never sees the key (state ends "up"). Fix: a
     release of a key that went down in the same poll is applied at the start of the
     next poll, so a tap is down for exactly one frame. (Two taps in one frame are
     still one edge: that is raylib's polling design; `GetKeyPressed` sees both.)
  2. **An upstream bug in raylib's memory platform:** its "previous key state" copy
     loop covers only the first 260 keys (an Android limit it inherited). For
     everything above, such as the arrows, Home/End and F-keys, the previous state
     stays 0 forever, so `IsKeyPressed` fires on every frame the key is down. It
     showed as one arrow press moving the square two steps while D (key 68) was
     exact. The log (key 262 -> step 4, step 5) pointed at the platform, not at
     delivery. Fixed with one more exact-match substitution in
     `tools/raylib_nimix.py` (cover `MAX_KEYBOARD_KEYS`).
- **A flaky test, fixed by finding its cause.** The first test sent keys 0.25 s
  apart and failed intermittently. The key sequence was always right but the
  position was not: under TCG a frame is slow enough that two taps could land in one
  frame, which is one edge by design. The test now waits for the program's own
  acknowledgement (its log line) before sending the next key and asserts the exact
  sequence. A fixed sleep would only have hidden it.
- **Not yet:** mouse and touch (no pointing device in the launcher or on the event
  bus: V5e); key-repeat rate and delay are the keyboard's; no input method for
  non-US layouts (the Nim keymap is US-only too).

## The ASan/UBSan job must not use refc (2026-11-10)

**Found by CI** on PR #6: `make test-asan` failed on the new `test_key_vectors` with
`runtime error: member access within misaligned address 0x7 ... FreeCell` in Nim's
`system/alloc.nim`. It reproduced locally.

**Diagnosis (by elimination, not by guessing):** a 20-line program that only splits and
parses the 1,026-line vector string crashes the same way. Turning off UBSan's alignment
check turns it into a real `SEGV on unknown address 0x2` inside the allocator, so it is
a genuine crash and not a sanitizer false positive. `-d:useMalloc` is not the cause
(still crashes without it). **`--mm:refc` + AddressSanitizer crashes once the garbage
collector runs a cycle**; `--mm:arc` with the same flags is clean. Earlier tests
allocated too little for the GC ever to run, so the job passed and hid the problem.

**Fix:** the sanitizer job builds with `--mm:arc` (one flag, with the reason in the
Makefile). The whole ASan+UBSan run is clean with it, including every older test, and
the sanitizers now see every allocation, which is what the job's own comment said it
was for. Rejected: making the new test allocation-light so the GC never runs (it
would leave the next test that allocates to fail the same way, and the job would
still be checking less than it claims), and `-fno-sanitize=alignment` (it would turn a
real crash into a different real crash, and the alignment check is what found the
misaligned kernel stack earlier).

**Left as it was:** the valgrind job still uses refc with `tests/valgrind.supp` (the
documented refc stack-scan false positives); it passed in this CI run.
