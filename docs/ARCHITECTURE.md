# NimixOS Architecture

> **Status:** Design document — living reference, updated as decisions are made.
> Last updated: 2026-06-20
>
> **Current state:** All three kernel models (monolithic, SASOS, microkernel) boot to an interactive serial shell. wasm3 and mpaland/printf vendored.

---

## Vision

NimixOS is an experimental operating system written in Nim, targeting x86_64. The goal is to reach a full graphical OS — shell, desktop, network, applications — while exploring modern ideas that traditional OSes couldn't adopt because of legacy constraints.

The guiding question: *if you designed an OS today, knowing what we know about language safety, WebAssembly, structured concurrency, and capability security — what would you build?*

---

## The Three-Tier Model

```
┌─────────────────────────────────────────────────────────────────┐
│  TIER 1 — KERNEL  (Nim → native x86_64 ELF, ring 0)           │
│                                                                 │
│  Memory · Interrupts · Scheduling · Event Server               │
│  Capability Table · IPC Routing · Driver Probing               │
│                                                                 │
│  Rule: the kernel does as little as possible.                   │
│  It never touches filesystems, network protocols, or UI.        │
└────────────────────────┬────────────────────────────────────────┘
                         │  syscall gate (ring 0 → ring 3)
          ┌──────────────┴───────────────┐
          ▼                              ▼
┌─────────────────────┐      ┌──────────────────────────────────┐
│  TIER 2 — SERVERS   │      │  TIER 3 — APPS                   │
│  (native ELF, ring 3│◄────►│  (WebAssembly, ring 3)           │
│   trusted, you built│      │   untrusted, sandboxed, portable) │
│   and signed these) │      │                                  │
│                     │      │  hello.wasm                      │
│  display_server     │      │  browser.wasm                    │
│  media_server       │      │  editor.wasm                     │
│  net_server         │      │  game.wasm                       │
│  fs_server          │      │                                  │
│  registrar          │      │  Can only call host functions     │
│                     │      │  they were granted at launch.     │
└─────────────────────┘      └──────────────────────────────────┘
```

---

## Tier 1: Kernel

**Language:** Nim compiled via C backend to native x86_64 ELF.
**Ring:** 0 (supervisor mode).
**Build flags:** `--os:any --mm:arc -ffreestanding -nostdlib`

### What the kernel owns

| Subsystem | Responsibility |
|-----------|---------------|
| Physical memory manager | Frame allocation, zone management |
| Virtual memory manager | Page tables, address space creation |
| Heap allocator | `malloc`/`free` for kernel objects |
| Interrupt controller | PIC/APIC init, IDT, IRQ dispatch |
| Timer (PIT/HPET) | Scheduler tick, `sleep` countdown |
| Scheduler | M:N coroutine scheduling across kernel tasks |
| Event server | Pub/sub backbone — all tiers use this |
| Capability table | Unforgeable tokens gating resource access |
| IPC router | Routes messages between tiers |
| Driver registry | Probe loop at boot; drivers register here |
| SIP loader | Loads WASM modules, assigns capability sets |

### What the kernel does NOT own

- Filesystems (that is `fs_server`)
- Network protocols (that is `net_server`)
- Display/compositor (that is `display_server`)
- Audio/video routing (that is `media_server`)
- Application registry (that is `registrar`)

### Kernel model (compile-time selectable)

Selected with `-d:kernelModel=<model>`:

| Model | Description |
|-------|-------------|
| `monolithic` | Default. All kernel subsystems in one address space, direct calls. |
| `microkernel` | Minimal kernel; servers run with stronger hardware isolation. |
| `sasos` | Single Address Space OS (Singularity-style). Language-enforced isolation instead of page-table switches. Fastest IPC. |

The model affects **how the kernel implements** the scheduler and IPC traits. The API exposed to servers and apps is identical across all models.

---

## Tier 2: System Servers

**Language:** Native ELF binaries (Nim, C, or any language that produces ELF).
**Ring:** 3 (user mode), isolated by page tables.
**Trust level:** High — these are built and signed by the OS distributor.
**Started by:** Kernel at boot via the server startup sequence (analogous to QNX's startup script or BeOS's launch daemon).

System servers are the OS runtime. They provide all services that apps consume.

### Core servers

| Server | Responsibility | Analogues |
|--------|---------------|-----------|
| `registrar` | App registry, capability grants, MIME types | BeOS registrar, macOS LaunchServices |
| `fs_server` | VFS, FAT32/ext2, disk cache | BeOS BFS server, QNX io-blk |
| `net_server` | TCP/IP stack, DNS, sockets | BeOS net_server, QNX io-pkt |
| `display_server` | Compositor, window manager, input dispatch | BeOS app_server, Wayland compositor |
| `media_server` | Audio/video routing, codec pipeline, real-time mixing | BeOS media_server |
| `device_manager` | PCI scan, hotplug, driver lifecycle | BeOS device_manager, udev |

### Why native ELF (not WASM) for servers

- **Performance ceiling:** Media mixing, TCP packet processing, and GPU compositing need raw native speed, SIMD, and zero interpreter overhead.
- **Privileged access:** Servers legitimately need `mmap`, DMA buffers, and direct device register access via capabilities. These are appropriate for trusted code you compiled yourself.
- **Existing ecosystem:** Port lwIP (net), Mesa (GPU), FreeType (fonts) — these are battle-tested C codebases. Compile to ELF, run as a server. No WASM port needed.
- **Server ↔ server IPC:** Two ELF servers can use shared memory + lock-free queues for zero-copy, microsecond-latency message passing — no kernel mediation needed.

---

## Tier 3: Applications

**Format:** WebAssembly (`.wasm` modules).
**Ring:** 3, but isolated by the WASM sandbox rather than (or in addition to) page tables.
**Trust level:** Untrusted — arbitrary third-party code.
**Started by:** `registrar` or shell `load` command.

### Why WASM for apps

- **Isolation without page-table overhead:** The WASM runtime checks every memory access. An app cannot read outside its linear memory or call a host function it wasn't granted. In SASOS mode this happens with no page-table switch.
- **Capability-gated imports:** A WASM module declares its imports at compile time. The loader checks each import against the app's granted capabilities. If the capability isn't held, the import is refused and the app doesn't load.
- **Portable binary:** The same `.wasm` binary runs on any architecture NimixOS is ported to. No recompile, no architecture-specific packages.
- **Verifiable:** Bytecode is type-checked before execution. Malformed or malicious structure is rejected at load time.

### WASM host ABI

The functions a WASM app can import (subject to capabilities):

```
# I/O
env.serial_write(ptr, len)              cap: CAP_SERIAL
env.fs_open(path_ptr) → fd             cap: CAP_FS_READ
env.fs_read(fd, buf, len) → n          cap: CAP_FS_READ
env.fs_write(fd, buf, len) → n         cap: CAP_FS_WRITE
env.fs_close(fd)                        cap: CAP_FS_READ

# Messaging
env.chan_open(name_ptr) → handle        cap: CAP_IPC
env.chan_send(handle, ptr, len)         cap: CAP_IPC
env.chan_recv(handle, ptr, len) → n     cap: CAP_IPC
env.chan_close(handle)                  cap: CAP_IPC

# Events
env.event_subscribe(topic_ptr) → token cap: CAP_EVENTS
env.event_publish(topic, ptr, len)     cap: CAP_EVENTS
env.event_wait(token, ptr) → n         cap: CAP_EVENTS
env.event_poll(token, ptr) → n         cap: CAP_EVENTS

# Process
env.sip_spawn(path_ptr, caps[])→ sipid cap: CAP_SPAWN
env.sip_wait(sipid) → exit_code        cap: CAP_SPAWN
env.sip_exit(code)                      (always available)
```

---

## IPC: How the Tiers Talk

### Channel taxonomy (by latency)

| Channel type | Peers | Mechanism | Latency |
|-------------|-------|-----------|---------|
| `LocalChan[T]` | Coroutines in same server/SIP | Lock-free SPSC/MPMC queue (arsenal) | ~10 ns |
| `SipChan[T]` | App (WASM) ↔ Server (ELF) | Kernel-mediated, event server routing | ~100 ns |
| `ServerChan[T]` | Server ↔ Server (ELF ↔ ELF) | Shared memory ring buffer, no kernel hop | ~50 ns |
| `NetChan[T]` | Cross-machine (future) | Serialized over network | ~1 ms+ |

**All four look identical to the caller.** The type system selects the implementation. A task does not need to know where the other end lives.

```nim
# This code is the same regardless of where `target` lives:
let ch = connect[AudioMsg](target, caps)
await ch.send(AudioMsg(freq: 440, duration: 1000))
let reply = await ch.recv(AudioReply)
```

### App → Server (the common case)

```
App (WASM)
  └── env.chan_send("media_server", PlayAudio{...})
        └── WASM host ABI (capability check: CAP_IPC ✓)
              └── Kernel IPC router
                    └── media_server mailbox (lock-free queue)
                          └── media_server coroutine wakes, processes message
                                └── reply routed back to app
```

### Server ↔ Server (high speed)

```
fs_server                          net_server
  └── shared memory region  ◄────► lock-free ring buffer
        (mapped into both address spaces via kernel mmap capability)
        zero-copy, no kernel hop, ~50ns round trip
```

### Kernel → All (event broadcast)

```
Kernel event server
  └── publish("dev.disk.added", DeviceInfo{...})
        └── fs_server (subscribed) → wakes, mounts new device
        └── device_manager (subscribed) → logs event
        └── any app with CAP_EVENTS + subscribed to "dev.*" → notified
```

---

## Concurrency Model

### Structured concurrency everywhere

Every task has a structured lifetime — it is spawned inside a scope and cannot outlive it. When the scope exits, all children are cancelled. No orphaned coroutines, no leaked resources.

```nim
scope "media playback":
    let decoder = spawn decoderTask(file)
    let mixer   = spawn mixerTask()
    let output  = spawn outputTask()
    await all([decoder, mixer, output])
# All three are guaranteed dead here, resources freed
```

### M:N scheduling

- **N** kernel tasks (one per CPU core eventually, one for now)
- **M** coroutines multiplexed onto those tasks
- When a coroutine blocks (waiting on a channel, event, or I/O), the kernel task picks the next ready coroutine — no thread context switch

Inside each server (ELF): coroutines handle requests concurrently.
Inside each WASM app: one coroutine runs the WASM interpreter (async WASM via wasm3's stackful coroutine support is a future option).

### Supervision trees

```
kernel supervisor
  ├── fs_server      → crash: restart, notify dependents
  ├── net_server     → crash: restart, notify dependents
  ├── display_server → crash: restart, apps get chan error
  └── media_server   → crash: restart

app supervisor (per-app)
  └── hello.wasm    → crash: clean up its capabilities, notify parent
```

When a supervised actor crashes: the event server publishes `sip.exit.<id>`. The supervisor restarts it. Channels to that actor return `mrCrashed`. Apps handle it, retry, or surface the error. No kernel panic, no lost state from other apps.

---

## Capability System

A capability is a `distinct uint64` — an unforgeable token. You cannot forge one, guess one, or copy one across a SIP boundary without the kernel explicitly granting it.

```nim
type SipCapability* = distinct uint64

# Standard capabilities
const
  CAP_SERIAL*   = SipCapability(1)
  CAP_FS_READ*  = SipCapability(2)
  CAP_FS_WRITE* = SipCapability(3)
  CAP_IPC*      = SipCapability(4)
  CAP_EVENTS*   = SipCapability(5)
  CAP_SPAWN*    = SipCapability(6)
  CAP_NET*      = SipCapability(7)
  CAP_DISPLAY*  = SipCapability(8)
  CAP_AUDIO*    = SipCapability(9)
```

At app launch, the `registrar` reads the app's manifest, checks user permissions, and grants a capability set. The SIP loader uses that set to bind only the allowed WASM imports. An app that doesn't hold `CAP_NET` literally cannot call `env.chan_open("net_server")` — the binding is refused before any code runs.

Servers hold broader capabilities (they are trusted). They can further subdivide and delegate capabilities to apps — a capability is attenuated, never amplified. An app can receive a restricted `CAP_FS_READ` scoped to one directory and pass it to a child SIP, but cannot escalate it to full filesystem access.

---

## Boot Sequence

```
1. GRUB loads kernel ELF via Multiboot2
2. Kernel init:
   a. Physical memory manager
   b. Virtual memory manager + heap
   c. PIC 8259A init (remap IRQs to 0x20-0x2F)
   d. PIT timer (100Hz tick)
   e. IDT (exception + IRQ handlers)
   f. Driver registry probe loop
   g. Event server init
   h. Scheduler init
   i. TSS + syscall gate (ring 0↔3)
3. Server startup sequence (kernel spawns as ELF processes):
   a. registrar  (must be first — grants capabilities to others)
   b. fs_server  (mounts boot device)
   c. device_manager (PCI scan, hotplug)
   d. net_server
   e. display_server
   f. media_server
4. registrar reads startup manifest → launches autostart WASM apps
5. Shell (WASM or ELF) appears
```

---

## Filesystem Layout (future)

```
/
├── boot/
│   └── kernel.elf
├── system/
│   ├── servers/
│   │   ├── registrar
│   │   ├── fs_server
│   │   ├── net_server
│   │   ├── display_server
│   │   └── media_server
│   └── drivers/          ← kernel driver modules (if modular)
├── apps/
│   ├── shell.wasm
│   ├── browser.wasm
│   └── editor.wasm
├── dev/                  ← device namespace (managed by device_manager)
└── data/                 ← user data
```

---

## Design Principles

1. **Least privilege by default.** Every SIP starts with no capabilities. The registrar grants only what the manifest declares. Users can further restrict.

2. **Crash isolation.** A crashing server or app never takes down the kernel or other apps. Supervision trees handle restarts automatically.

3. **Location-transparent IPC.** Code that sends a message doesn't know or care if the receiver is a local coroutine, a server process, or (eventually) a remote node. The channel abstraction is uniform.

4. **No shared mutable state between SIPs.** The only legal cross-SIP communication is through typed channels. No raw pointers, no shared memory regions without explicit capability grants.

5. **Model portability.** Apps written for NimixOS work identically whether the kernel runs as monolithic, microkernel, or SASOS. The WASM host ABI is the stable interface; the model is an implementation detail.

6. **Structured lifetimes.** Every task is born inside a scope and dies when that scope exits. No orphans. Resources are freed deterministically (ARC + structured concurrency).

7. **Modern primitives, not legacy compatibility.** We do not emulate POSIX, Win32, or any existing ABI. We take the ideas that worked (channels, supervision, capabilities) and leave behind the ideas that were compromises (signals, shared memory IPC, flat process model).
