---
name: project-concurrency
description: NimixOS concurrency model — kernel scheduler vs CPS dispatcher vs future directions
metadata: 
  node_type: memory
  type: project
  originSessionId: 2aeec000-d2c7-4794-ad9a-e8cd0ef40956
---

## Two concurrency layers (by design, not accident)

**Kernel layer — preemptive ring scheduler:**
- 3 classes: Realtime > Server > App
- PIT-driven preemption (100Hz), intrusive doubly-linked ring per class
- Stays simple and elegant — no plans to replace it
- Handles: interrupt dispatch, context switch, sleep/wakeAfter, FPU save/restore

**Dispatcher layer — CPS coroutines:**
- `nim-cps` library, single-threaded run loop
- Each in-flight request becomes a heap-allocated Continuation
- Priority queue: (class, deadline, arrival_time) — 4 QoS classes
- Starvation prevention: any request waiting >500ms gets bumped one class
- No locks needed in hot path (single-threaded)
- This is the focal point for control, QoS, and high concurrency

## Future CPS expansion (planned, not yet)
- Media player multiplexing
- Async I/O
- General server coroutine pattern

## Driver threading (research pending)
- Long-term: possibly OS threads for drivers, inspired by NetBSD rump kernel
- Rump kernel approach: ~1000-line `rumpuser` hypercall boundary, runs as userspace driver server
- Prerequisites not yet built: `irqSubscribe(vec, cap)` + DMA-safe region mapping to userspace
- Do NOT build rump infrastructure until those primitives exist naturally

## Why this split
The kernel scheduler handles hard-RT (interrupt response, timer). The dispatcher handles soft-RT (QoS, concurrency at scale). Mixing them would make both worse. The kernel stays minimal and auditable; the dispatcher carries all the policy complexity.
