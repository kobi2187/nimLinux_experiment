---
name: feedback-code-size
description: User prefers files kept short — split large files into focused modules
metadata: 
  node_type: memory
  type: feedback
  originSessionId: b6b7a5b8-f231-4531-95b6-fb1a31457386
---

Split files that grow above ~100 lines into focused submodules that are imported.

**Why:** Code should remain simple, readable, and elegant. Large files are harder to reason about.

**How to apply:** When writing or refactoring, if a file exceeds ~100 lines, extract logical groups into separate modules (e.g. `ipc_encode.nim`, `fs_logic.nim`) and import them. This applies to both kernel and app code. The scaffold pattern (logic/kmod/elf split) is already an example of this principle.
