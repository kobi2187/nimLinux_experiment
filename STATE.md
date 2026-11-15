# STATE.md — Current Status

Last updated: 2026-11-15 (branch `ccr-56330414-wo65nx`, synced to `master` after PR #11 merged). Earlier
states of this file are in git history; this file holds the CURRENT state only.

## Repository facts (so no session rediscovers them)
- Default branch is **`master`**; `main` is stale (14+ commits behind). Base new work on `master`.
- Work on the session branch, push only there, PRs are drafts, never merge unless the human asks.
- Toolchain: Nim 2.2.4 at `/opt/nimtc/nim-2.2.4/bin` (put it on PATH); QEMU 8.2.2 (TCG) + OVMF.
- Safe make targets: `test`, `test-devices`, `test-qemu-models`, `test-structured`, `disk-add-apps`.
  **Never bare `make`** (its default target opens an interactive QEMU).
- Gate before any push: all four test targets green, run once and alone (AGENTS.md, VERIFY).
- Last gate: `make test` pass; `test-devices` 39/39; `test-qemu-models` 16/16 x3; `test-structured` 47/47.

## Awaiting human (decisions only the human can make)
| asked | question | my recommendation |
|-------|----------|-------------------|
| 2026-11-14 | S8c: language domains (checked safe Nim subset, Singularity style) for the SASOS model | keep PROPOSED; build after the contract layer, when a second isolation kind has a user |
| 2026-11-15 | `main` is stale: fast-forward it to `master` or abandon it | fast-forward, or delete and make `master` the only branch |
| 2026-11-15 | AGENTS.md revision is an experiment: judge it from the Process log below | none needed; revert from `docs/archive/` if it does not help |
| 2026-11-15 | K1 contract/IDL: how a server's API is described and how client libraries are produced | a proposal comes first (options and a pick) |

## Built (the foundation, by layer; details in BACKLOG status table and DECISIONS)
- **Authority:** per-task handle tables with generations, rights that only narrow, badges, move/duplicate/
  close; channel endpoint pairs; `spawn` guarded by a process handle; manifests + system policy.
- **Memory isolation:** every ring-3 task on its own page tables; buffers owned per 4 KB page (move/lend/
  share, in channel messages); all RAM mapped for the kernel only.
- **Waiting and cost:** `Wait` on a set of channel ends; batch read/write; per-task syscall counts.
- **Display/graphics:** virtio-gpu console, display ABI v2 (modes), raylib on NimixOS pixel-exact, input.
- **Services still scaffolding:** ambient `chanSend`, event topics, first-present display, the shell as the
  one ambient authority (ARCHITECTURE §0 lists scaffolding).

## Next in order
K1 contract/IDL → K3 device ports (then S3b removes the ambient calls) → K2 dispatcher stage 2 →
E1 event server → S2k-b2 (one handle table for every object) → V6 render-server slices.

## Process log (AGENTS.md experiment; see AGENTS.md, last section)
| session | rediscovered facts | pushes without gate | test-fault reds | human repeats | ORIENT lines |
|---------|-------------------|---------------------|-----------------|---------------|--------------|
| 2026-11-15 (before the revision, S8b + S3a) | 3 (default branch, bare `make`, `-fPIE` link) | 0 | 4 | 2 | ~3,700 |
