---
name: feedback-performance
description: No premature optimization — let data structures and system design drive performance
metadata: 
  node_type: memory
  type: feedback
  originSessionId: b6b7a5b8-f231-4531-95b6-fb1a31457386
---

Don't optimize prematurely. Performance comes from correct data structure choice and good system design, not micro-optimizations.

**Why:** Premature optimization obscures intent, introduces bugs, and optimizes the wrong thing. The dispatcher's priority queue is O(log n) not because we micro-tuned it, but because a min-heap is the right structure for the job. That's the level to think at.

**How to apply:**
- Choose the right data structure upfront (e.g. min-heap for priority queue, intrusive ring for O(1) scheduler pick-next, flat array for O(1) slot access by index)
- Design the system so the hot path is naturally cheap (e.g. zero-copy data plane via region caps bypasses the IPC layer entirely)
- Don't hand-unroll loops, avoid early inlining, don't replace readable code with bit tricks unless a profiler shows it matters
- If something feels slow, measure first — then fix the data structure or the design, not the code

**What counts as good structural performance decisions (already made):**
- Intrusive doubly-linked ring per scheduler class → O(1) pick-next
- Flat `tasks[32]` array → O(1) access by slot index
- Region cap tokens for bulk data → zero copies on the data path
- Dispatcher as single-threaded CPS run loop → no lock contention
- Hand-rolled MsgPack encoder only in kernel context → avoids full stdlib overhead where genuinely needed

**What to avoid:**
- Replacing `for x in items` with manual index loops "for speed"
- Inlining procs that hurt readability without a measured bottleneck
- Bit-packing structs without a proven memory pressure reason
- Premature cache-line alignment or SIMD without profiling data
