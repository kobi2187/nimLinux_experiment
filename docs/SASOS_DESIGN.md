# NimixOS SASOS Design — Single Address Space OS

> Answers: can apps be added/removed? do they share the space? is there one space or two?

---

## What "Single Address Space" Means

In a traditional OS each process gets its **own virtual address space** — the MMU reloads page tables on every context switch. In SASOS **all code is mapped into the same virtual address space simultaneously**. No page table reload on context switch — that is the speed win.

x86_64 gives 48-bit virtual addresses = 256 TB of address space. That is more than enough to hold the kernel, all servers, all running WASM app instances, and their linear memories simultaneously — with room to add and remove them at runtime.

---

## Can You Add and Remove Apps Dynamically?

**Yes.** The address space is a resource like any other. When a new WASM app is loaded:

1. The SIP loader allocates a virtual region (e.g. 4 MB aligned) for its linear memory.
2. wasm3 maps the WASM module's code into a separate read-execute region.
3. A `SipId` and capability set are created for it.
4. When the app exits or is killed, those regions are unmapped and the `SipId` is retired.

This is identical to how a JVM loads and unloads class bytecode — dynamic, runtime-managed, no reboot needed.

ELF servers work the same way but are loaded earlier in boot and are expected to stay resident.

---

## Isolation: How Apps Are Kept Apart Without Page Tables

Two complementary mechanisms cover the two tiers of trust:

### Trusted code (ELF servers — Nim, compiled by you)

- **Capability tokens** (`SipCapability = distinct uint64`): unforgeable by construction.
  Every IPC send/recv is checked against the current SIP's capability set.
  No token → `mrInvalid` before any data moves.
- **Nim's type system**: you cannot cast a `SipCapability` without an explicit `cast[]`,
  which is the audit trail. The compiler enforces the discipline.
- No runtime overhead beyond an array lookup.

### Untrusted code (WASM apps — arbitrary third-party)

- **wasm3 bounds-checking**: every memory load/store in WASM bytecode is checked against
  the module's linear memory bounds before execution. A WASM app cannot read outside
  its allocated region — the interpreter enforces this on every instruction.
- **Host ABI capability gate**: each `env.*` import is only bound if the SIP holds
  the matching capability. A WASM app without `CAP_NET` cannot even call `chan_send`
  to the net server — the import binding is refused at load time.

---

## Address Space Layout — Option B (Chosen)

We use a **hybrid two-zone model**, not a single flat space:

```
┌──────────────────────────────────────────────────────────┐
│  Ring 0  (kernel zone)                                   │
│  kernel code + data + stack                              │
│  Protected by hardware: ring 3 code cannot read here     │
│  Entry only via syscall gate (LSTAR MSR)                 │
├──────────────────────────────────────────────────────────┤
│  Ring 3  (shared SASOS zone)                             │
│                                                          │
│  ELF servers (trusted, capability-isolated)              │
│    net_server, fs_server, display_server...              │
│    ← communicate via direct ServerChan ring buffers      │
│    ← no page table switch between servers (~10 ns IPC)   │
│                                                          │
│  WASM runtime instances (one wasm3 per app)              │
│    each app: [linear memory region | code region]        │
│    ← wasm3 sandbox enforces bounds on every access       │
│    ← capability tokens gate all host ABI calls           │
│    ← no page table switch app↔server (~100 ns via SipChan│
│                                                          │
│  All ring-3 entities share one page table.               │
│  Context switch between them = save/restore registers    │
│  (no CR3 reload, no TLB flush)                          │
└──────────────────────────────────────────────────────────┘
```

### Why not a third zone for WASM apps?

A separate page table for WASM apps (Zone 3) would add a CR3 reload on every
app→server call. Given that wasm3 already bounds-checks every access, the extra
hardware isolation buys little while paying a ~1000 ns page table switch cost.
If a stronger guarantee is needed later, it can be added without changing the API —
just swap in a page-table-per-app allocator behind the same `sipLoad()` call.

---

## What Changes Between Kernel Models

The address space layout is the same for all three models. What differs:

| Model | IPC mechanism | Scheduler | Isolation enforcement |
|-------|--------------|-----------|----------------------|
| Monolithic | Direct call, shared state | Round-robin | None (trust all) |
| SASOS | Direct copy, capability-checked | Round-robin + SIP-aware yield | Capability tokens + WASM sandbox |
| Microkernel | Double-copy through kernel staging buffer | 4-level priority (Critical→Low) | Capability tokens + staging validates messages |

The shell, drivers, event server, and host ABI are **identical** across all three.
Only the internals of `ipc.send` / `ipc.recv` / `scheduler.spawn` differ.

---

## Vendored Libraries

| Library | Location | Use |
|---------|----------|-----|
| [wasm3](https://github.com/wasm3/wasm3) | `vendor/wasm3/` | WASM interpreter — runs app bytecode, bounds-checks linear memory |
| [mpaland/printf](https://github.com/mpaland/printf) | `vendor/printf/` | `sprintf`/`snprintf` with zero stdlib deps — kernel-safe formatted output |
| [arsenal](https://github.com/kobi2187/arsenal) | `vendor/arsenal/` | Lock-free queues, atomics, bit-ops, allocators |

---

## Future: Guard Pages

Even within the shared ring-3 zone, WASM linear memory regions will be bounded
by unmapped guard pages (one 4 KB page before and after each region). If wasm3
has a bounds-checking bug, the access faults at the guard page before reaching
any server memory. This adds defence-in-depth without page table switches.
