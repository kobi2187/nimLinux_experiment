---
name: project-architecture
description: "Core NimixOS architecture — what it is, how the 3 models work, build system, key design decisions"
metadata: 
  node_type: memory
  type: project
  originSessionId: 2aeec000-d2c7-4794-ad9a-e8cd0ef40956
---

NimixOS is an OS-as-a-library project: a collection of well-tested, composable OS modules that can be wired into three distinct kernel architectures from the same shared codebase.

**Three kernel models, one codebase:**
- `monolithic` — everything in ring 0, direct function calls, ring-buffer IPC
- `microkernel` — double-copy staging buffer IPC, hardware isolation simulated
- `sasos` — Single Address Space OS (Singularity-style), capability-gated direct ring-buffer IPC, Nim type system enforces isolation instead of MMU

**Build output:** 3 separate ISO files (or one `iso-all` with GRUB menu). Each ISO is compiled with `-d:kernelModel=X`. The model is selected at compile time via `kernel/config.nim` (`KernelModel` strdefine). All three share `kernel/init/main.nim`; model-specific wiring lives in `kernel/models/{monolithic,microkernel,sasos}.nim`.

**Shared logic via vtable traits:** `kernel/traits/scheduler.nim` and `kernel/traits/ipc.nim` define `SchedulerVTable` / `IpcVTable`. Each model fills these tables with its own implementations. Higher-level code (shell, servers, apps) imports only the trait — never a concrete model.

**Servers / apps pattern:**
- ELF servers: trusted OS-level components (fs_server, ping_server, dispatch_server, etc.) — like BeOS servers or Windows services
- WASM apps: sandboxed user applications, capability-gated
- Apps are thin clients — they send one MsgPack control message and wait; all policy/logic lives in servers

**Wire formats:**
- MsgPack: control plane (IPC commands, capability grants, service discovery)
- FlatBuffers: data plane (media frames, bulk transfers) — zero-copy with region caps
- Zero-copy achieved via capability-scoped memory region tokens, not data copying

**Concurrency model:**
- Kernel: preemptive ring scheduler (3 classes: Realtime > Server > App), stays simple and elegant
- Dispatcher server: CPS (nim-cps) coroutines internally — handles thousands of concurrent requests, priority queue with starvation prevention
- Long-term vision: expand CPS usage to media player multiplexing, async I/O; kernel scheduler stays preemptive for interrupt handling
- Possibly OS threads for drivers (rump kernel model, NetBSD-inspired) — research pending

**Parity goal:** All 3 models should be functionally equivalent. Monolithic was furthest ahead; others are catching up. If a feature gap is not obvious, it can lag until insights and research catch up — no forced parity on unclear problems.

**Why:** See [[project_vision]] and [[project_build_system]]
