---
name: project-vision
description: "NimixOS north star — what it is, what it is not, ranked goals"
metadata: 
  node_type: memory
  type: project
  originSessionId: 2aeec000-d2c7-4794-ad9a-e8cd0ef40956
---

NimixOS is a Nim-native OS-as-a-library targeting QEMU, where the same module library can be composed into monolithic, microkernel, or SASOS kernels. It is not a Linux clone or a research toy — it is a real, interactive OS with game-engine-quality graphics (raylib/naylib), a dispatcher-based QoS concurrency engine, and capability tokens as the sole access control mechanism.

**Ranked goals:**
1. Composable, testable OS modules — each behind a clean interface, independently testable on the host
2. Three interchangeable kernel models from one codebase — monolithic/microkernel/SASOS
3. Dispatcher server as the QoS/concurrency hub — all app I/O routes through it; apps are thin
4. Coroutines (CPS) as the concurrency model for servers and high-concurrency code
5. Raylib + naylib for graphics and audio — PLATFORM_CUSTOM backend, zero-copy framebuffer
6. Capability tokens as the only access control — no ambient authority anywhere

**Non-goals:**
- Linux ABI compatibility
- Real hardware support (QEMU only for now; rump kernel deferred)
- Monolithic kernel performance (performance comes from design, not micro-optimization)

**Design axioms:**
- Apps never call kernel I/O directly — everything through dispatcher
- Control plane = MsgPack (inspectable), data plane = FlatBuffers or region token (zero-copy)
- Kernel stays policy-free — it executes what dispatcher says
- Dispatcher is single-threaded (CPS) — no locks in hot path
- Coroutines everywhere (long-term); preemptive kernel scheduler stays for interrupt handling

**How:** See [[project_architecture]] for implementation details.
