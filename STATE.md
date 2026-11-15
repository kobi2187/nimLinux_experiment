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

## The picture (rewritten at every STEP BACK; 2026-11-15)

**1. Where we stand**
| # | goal (VISION) | state | evidence / gap |
|---|---------------|-------|----------------|
| 1 | composable, host-testable modules | **strong** | pure libraries with host tests: handles, channels, buffers, address spaces, manifests, arena |
| 2 | three interchangeable kernel models | **partial; unproven for the newest work** | `test-qemu-models` (16 tests) passes on all three, but the 39-test `test-devices` suite (isolation, handles, spawn, buffers) runs on the monolithic kernel only |
| 3 | dispatcher as the QoS/concurrency hub | **weak** | Stage 1 exists but is in no app's path; K1 and K2 not started |
| 4 | CPS coroutines for servers | partial | dispatcher only |
| 5 | raylib graphics + audio | strong for direct rendering | pixel-exact on NimixOS; render server (V6) and audio server not started |
| 6 | capabilities as the only access control | **mechanism strong, adoption weak** | handles, rights, spawn, per-task spaces tested; real traffic still uses ambient `chanSend`, event topics, first-present display; the shell holds every right |

**2. Leaves I do on my own** (CLEAR: local, reversible, no frozen API, in this order)
1. Run `test-devices` against the sasos and microkernel kernels; fix model-specific failures (closes goal-2 gap).
2. valgrind/ASan pass on the new libraries (launcher/manifest, addr_space, arena) and the missing ones.
3. Guard pages below task stacks (the page-splitting code exists; local to `kspace`/`addr_space`).
4. R9: retire the ping/dispatch kernel modules in the microkernel model.
5. V7c: actor-backed `background`/`mailbox` behind RUI's API (threads off).
6. V4b: measure arena sizing and per-class budgets, then set them from the numbers.
7. V2c: sub-tick timer (S4).

**3. Needs direction** (each will be asked in the question template; first = blocks the most)
- **K3 device-port interface** (blocks S3b, M1/M2, V6, most R-moves): a new boundary.
- **K1 contract/IDL** (blocks K2 and every server's client library): a frozen API.
- **E1 event server**: how a subscription is a handle; a new subsystem boundary.
- **S2k-b2** fold the buffers table into the handle table: changes the frozen buffers API (logged in both projects).
- **K2 dispatcher stage 2**, **R0 device capabilities** (interrupt/MMIO/DMA as handles), **V6 render server** (12 decisions open), **V8 userspace WASM host**, **S8c language domains**.
- **`main` branch**: fast-forward or delete.

**4. Results you could see next** (you choose the focus; each is a demo you can run)
| # | what you would see | what it takes | decisions needed |
|---|--------------------|---------------|------------------|
| a | **Three kernels, one table**: the 39-test device suite passing on monolithic, microkernel and SASOS | leaf 1 only (hours) | none |
| b | **Keys reach only the focused app**: a "keylogger" app started beside a game gets nothing, the game gets every key; the shared `input` topic is gone | K3 device port + E1 events + S3b for input | K3, E1 |
| c | **The shell as an ordinary program**: `shell.elf` started by the launcher with only the rights its manifest grants; the kernel keeps a serial console | R5/R6 console server + userspace shell (needs b's patterns) | K3, K1 |
| d | **Two windows on screen**, overlapping, each drawn by a different app, composed by a render server; a hostile client is refused | V6 slices (needs K1, K2, K3, M1, M2) | the 12 open V6 decisions, K1, K2, K3 |
| e | **A WASM app (the RUI counter) running in a userspace host** with no WASM code in the kernel | V8 (needs K2) | V8 boundary |
| f | **Sound through an audio server** (440 Hz tone via a session) | V10 (needs K3) | K3 |

## Next in order
K1 contract/IDL → K3 device ports (then S3b removes the ambient calls) → K2 dispatcher stage 2 →
E1 event server → S2k-b2 (one handle table for every object) → V6 render-server slices.

## Process log (AGENTS.md experiment; see AGENTS.md, last section)
| session | rediscovered facts | pushes without gate | test-fault reds | human repeats | ORIENT lines |
|---------|-------------------|---------------------|-----------------|---------------|--------------|
| 2026-11-15 (before the revision, S8b + S3a) | 3 (default branch, bare `make`, `-fPIE` link) | 0 | 4 | 2 | ~3,700 |
