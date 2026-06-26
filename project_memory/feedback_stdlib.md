---
name: feedback-stdlib
description: Prefer Nim stdlib and high-level abstractions over low-level pointer/bit manipulation
metadata: 
  node_type: memory
  type: feedback
  originSessionId: b6b7a5b8-f231-4531-95b6-fb1a31457386
---

Always prefer high-level Nim code. The kernel supports `--mm:arc` so GC-managed types (seq, string, Option, Result) work throughout.

**Why:** Readability, correctness, maintainability. Low-level code (raw pointers, manual bit shifting, hand-rolled loops) should only appear when stdlib genuinely can't reach (e.g. kernel `--os:any` context where osalloc isn't available). The kernel uses `--mm:arc` so there is no GC pause concern.

**How to apply:**
- In kernel (`--os:any`, `--mm:arc`): `seq`, `string`, `Option[T]`, `Result[T,E]` all work — use them freely
- In `--os:standalone` apps: use msgpack4nim, sequtils, strutils, options etc. freely — libc stubs exist
- Never manually bit-shift to encode/decode if a library (msgpack4nim, flatbuffers) handles it
- Never write `while s[i] != '\0': inc i` when `len(s)` or cstring helpers exist
- `openArray`, `seq`, `string` over raw pointer + length pairs wherever possible
- Prefer `Result[T,E]` / `Option[T]` over out-params and negative error codes in new code
- Only drop to inline asm or raw pointers when writing hardware register access (I/O ports, MSRs, CPUID)
