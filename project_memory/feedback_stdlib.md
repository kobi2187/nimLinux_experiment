---
name: feedback-stdlib
description: Prefer Nim stdlib and high-level abstractions over low-level pointer/bit manipulation
metadata: 
  node_type: memory
  type: feedback
  originSessionId: b6b7a5b8-f231-4531-95b6-fb1a31457386
---

Use Nim's stdlib whenever possible. Prefer high-level code over low-level.

**Why:** Readability, correctness, maintainability. Low-level code (raw pointers, manual bit shifting, hand-rolled loops) should only appear when stdlib genuinely can't reach (e.g. kernel `--os:any` context where osalloc isn't available).

**How to apply:**
- In `--os:standalone` apps: use msgpack4nim, sequtils, strutils, options etc. freely — they compile now that libc stubs exist
- In `--os:any` kernel: stdlib is limited, but use what's available (e.g. `$` for string conversion, `options`, `result` types)
- Never manually bit-shift to encode/decode if a library (msgpack4nim, flatbuffers) handles it
- Never write `while s[i] != '\0': inc i` when `len(s)` or cstring helpers exist
- `openArray`, `seq`, `string` over raw pointer + length pairs wherever possible
- Prefer `result` type / `Option[T]` over out-params and negative error codes in new code
