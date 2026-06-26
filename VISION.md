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
- Control plane = MsgPack (inspectable), data plane = FlatBuffers or region token (zero-copy)
- Kernel stays policy-free — it executes what dispatcher says, in the order dispatcher says
- Dispatcher is single-threaded (CPS) — no locks needed in hot path
- Kernel scheduler stays preemptive and simple — it handles hard-RT; dispatcher handles soft-RT
- Region ref count reaches zero before regionFree — no dangling pointers

## Open questions

| # | Question | Resolving signal |
|---|----------|-----------------|
| 1 | Boot sequence for disk-loaded servers — does kernel wait for disk mount before spawning servers, or retry async? | When we implement boot-from-disk in Milestone 1 |
| 2 | Does dispatcher use IST entries for its Realtime class, or is PIT-driven preemption sufficient? | When dispatcher server is running under load |
| 3 | FlatBuffers schema ownership — defined per-server or in shared `schemas/` directory? | When we write the first FlatBuffers schema (Milestone 2) |
| 4 | OS threads for drivers (rump kernel pattern) — how does the rumpuser hypercall layer integrate with NimixOS coroutines? | After `irqSubscribe(vec, cap)` + userspace DMA mapping exist |
