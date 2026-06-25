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

## Open Questions

- UNCONFIRMED: Exact boot sequence for disk-loaded servers — does the kernel wait for disk mount before spawning servers, or retry asynchronously?
- UNCONFIRMED: Does the dispatcher use IST (Interrupt Stack Table) entries for its realtime class, or is PIT-driven preemption sufficient?
- UNCONFIRMED: FlatBuffers schema ownership — defined per-server or in a shared `schemas/` directory?
