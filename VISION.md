# VISION.md — NimixOS North Star

## What it is

NimixOS is an **OS-as-a-library**: a collection of well-tested, composable OS modules that
can be wired into three distinct kernel architectures (monolithic, microkernel, SASOS) from
one shared codebase. It targets QEMU only. It is not a Linux clone; it is a clean-room Nim
OS with game-engine-quality graphics and a dispatcher-based concurrency engine.

## What it is not

- Not a Linux ABI compatibility layer
- Not targeting real hardware (QEMU only; rump kernel integration deferred)
- Not optimised by micro-benchmarking — performance comes from design

## Ranked goals

1. **Composable, testable OS modules** — each behind a clean interface, independently
   testable on the host without QEMU
2. **Three interchangeable kernel architectures** — monolithic / microkernel / SASOS,
   functionally equivalent, compiled from the same codebase via `-d:kernelModel=X`
3. **Dispatcher server as the QoS/concurrency hub** — all app I/O routes through it;
   apps are thin MsgPack clients; all policy lives in servers
4. **CPS coroutines** as the concurrency model for servers and high-concurrency paths
   (dispatcher today; media player, async I/O next)
5. **Raylib + naylib** for graphics and audio — `PLATFORM_CUSTOM` backend, zero-copy
   framebuffer into virtio-gpu DMA region
6. **Capability tokens as the only access control** — no ambient authority anywhere

## Design axioms (never violate)

- Apps never call kernel I/O directly — all I/O goes through dispatcher
  (streams: the dispatcher brokers a session and governs it; steady-state
  data then flows on that session's ring — 2026-10-27, bulk_data.md)
- Control plane = MsgPack (inspectable), data plane = FlatBuffers or **buffer
  handle** (zero-copy). Mutable memory is never shared: a buffer is owned by
  one task or sealed; it moves or is lent (ipc/buffers.nim, frozen 2026-10-27)
- Kernel stays policy-free — it executes what dispatcher says, in the order dispatcher says
- Dispatcher is single-threaded (CPS) — no locks needed in hot path
- Kernel scheduler stays preemptive and simple — it handles hard-RT; dispatcher handles soft-RT
- Region ref count reaches zero before regionFree — no dangling pointers

## Decision principles (human, 2026-10-26)

- **Microkernel first**: functionality lives in servers; the kernel provides
  mechanism (scheduling, address windows, mailboxes, capabilities), not policy.
- **Actors + lightweight fibers**, never POSIX/OS threads (apps build
  `--threads:off`; no TLS).
- **Capabilities** are the authority — e.g. a server receives on its channel
  through a receive capability, not by name or pid.
- **Oskit libraries**: modular, encapsulated, behind small interfaces.
- Prerequisites that enable this basis are allowed (e.g. the interim
  `sti;hlt` blocking until block-on-mailbox lands).

## Rendering model and budgets (human, 2026-11-03)

**The server-provides model is the default and the experiment; exceptions are
allowed when a measured budget is missed and the cause can't be fixed within
the model; each exception is an ADR with its measurement.**

In practice:
- WASM apps (with RUI2 logic in the app) send draw commands to a native
  render server (raylib), which provides resources and composites.
- ELF apps and games may render client-side or in direct mode, as the
  measured exception.

End-to-end budgets: the yardstick for the model and for every exception.

| budget | target | gated where |
|--------|--------|-------------|
| key-to-pixel latency (key event in → changed pixels presented) | ≤ 2 frames = **33 ms p95** | KVM runs; TCG: tracked, not gated |
| RUI frame time at 60 fps (app layout + encode, plus server raster + composite + present) | **≤ 16.7 ms**, split app ≤ 4 ms / server ≤ 10 ms / present ≤ 2.7 ms | KVM; TCG tracked |
| draw commands per frame | steady state (one widget changed) **≤ 200** and ≤ 16 KB of stream; full repaint of a typical screen ≤ 2,000 | **CI, any accelerator** (deterministic count) |
| kernel calls per frame | **≈ 1 `ringSubmit`** per app frame (+ 1 wake); ≤ 4 kernel transitions per frame per app including present | **CI** (counted by the kernel) |
| idle | **0 frames** when nothing changed (RUI sleeps; the server presents nothing) | CI |

The model's cost is measured, not argued: the same RUI screen is rendered
in-process (RUI + raylib/rlsw linked into one ELF) and through the render
server (WASM RUI → commands → server → the same rlsw). Frame time,
key-to-pixel and counts are compared (BACKLOG: vertical slice, V9).

## Open questions

| # | Question | Resolving signal |
|---|----------|-----------------|
| 1 | Boot sequence for disk-loaded servers — does kernel wait for disk mount before spawning servers, or retry async? | When we implement boot-from-disk in Milestone 1 |
| 2 | Does dispatcher use IST entries for its Realtime class, or is PIT-driven preemption sufficient? | When dispatcher server is running under load |
| 3 | FlatBuffers schema ownership — defined per-server or in shared `schemas/` directory? | When we write the first FlatBuffers schema (Milestone 2) |
| 4 | OS threads for drivers (rump kernel pattern) — how does the rumpuser hypercall layer integrate with NimixOS coroutines? | After `irqSubscribe(vec, cap)` + userspace DMA mapping exist |
| 5 | SMP — when we add AP boot, `syscallScratchRsp` and `globalTss` must become per-CPU (via GS base MSR + `CpuLocal` struct + `swapgs`); `syscallTable` stays global (read-only). What does the `CpuLocal` struct look like and where does AP init live? | When AP bringup (APIC + SIPI) is started |
| 6 | ~~Per-app address spaces~~ **RESOLVED 2026-10-27**: per-app CR3 is the next kernel milestone (buffers Stage B); Stage A enforces buffer ownership by per-switch page rights in the shared space; SASOS keeps the shared space (type-system enforcement). | Signal arrived: app_server must be protected from its clients |
