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
- **Library**: Use `msgpack4nim` (pure Nim, MIT) — no C deps, idiomatic.
- **Dependency order**: msgpack4nim uses Nim stdlib (streams, etc.). Rather than hacking around missing stdlib, implement OS support layers in order so Nim's stdlib eventually works natively on NimixOS. Tasks are ordered accordingly in taskwarrior.

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

## Open Questions

- UNCONFIRMED: Exact boot sequence for disk-loaded servers — does the kernel wait for disk mount before spawning servers, or retry asynchronously?
