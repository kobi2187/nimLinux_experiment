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

**Ranked goals (VISION) — where they stand**
| # | goal | state | evidence / gap |
|---|------|-------|----------------|
| 1 | composable, host-testable modules | **strong** | pure libraries with host tests for handles, channels, buffers, address spaces, manifests, arena |
| 2 | three interchangeable kernel models | **partial, and unproven for the newest work** | `test-qemu-models` runs 16 tests on all three, but the 39-test `test-devices` suite (isolation, handles, spawn, buffers) runs on the monolithic kernel only |
| 3 | dispatcher as the QoS/concurrency hub | **weak** | Stage 1 actor loop exists but is not in any app's path; K1 (contract) and K2 (stage 2) not started |
| 4 | CPS coroutines for servers | partial | dispatcher only; no second user yet |
| 5 | raylib/naylib graphics + audio | strong for direct rendering | raylib is pixel-exact on NimixOS; the render server (V6) and audio server not started |
| 6 | capabilities as the only access control | **mechanism strong, adoption weak** | handles, rights, spawn authority, per-task address spaces all tested; but real traffic still uses ambient `chanSend`, event topics, first-present display, and the shell holds every right |

**Easy (small, low risk)**
- run the device suite against the other two kernel models (closes the goal-2 blind spot)
- `main` branch cleanup; valgrind pass on the new libraries; guard pages for task stacks (the page-splitting code already exists)
- R9 retire the ping/dispatch kernel modules in the microkernel model; V7c actor-backed `background`; V4b measure the arena sizing; V2c sub-tick timer

**Medium (a day or two of focused work each)**
- K3 device-port interface; E1 event server; S2k-b2 one handle table for every object; S3b remove the ambient calls (needs K3)

**Involved (real design, several steps)**
- K1 contract/IDL (a frozen API every server and SDK depends on); K2 dispatcher stage 2; R0 device-capability mechanisms (interrupts, MMIO, DMA as handles; the gate for moving every driver out of the kernel); V6 render server (7 slices); V8 userspace WASM host; S8c language domains

**Critical path:** K3 (device ports) unblocks S3b, M1/M2, V6 and most R-migrations; K1 unblocks K2 and every server's client library. R0 gates the driver moves.

**Where we are lacking:** the service layer. The foundation (authority, memory isolation, waiting, spawning) is largely done and tested, but only by tests that attack it. No real program uses it yet, and the old scaffolding still carries all real traffic. Mechanisms nothing consumes drift from what consumers will need.

**Focus:** (1) the quick check that the newest work holds on all three kernel models; (2) one thin vertical slice through the new mechanisms with a real consumer: the **input path** (device port, then event channel, then the app), which also removes the `input` topic keylogging hole. It exercises K3 and E1 end to end at small scale before K1 freezes anything.

## Next in order
K1 contract/IDL → K3 device ports (then S3b removes the ambient calls) → K2 dispatcher stage 2 →
E1 event server → S2k-b2 (one handle table for every object) → V6 render-server slices.

## Process log (AGENTS.md experiment; see AGENTS.md, last section)
| session | rediscovered facts | pushes without gate | test-fault reds | human repeats | ORIENT lines |
|---------|-------------------|---------------------|-----------------|---------------|--------------|
| 2026-11-15 (before the revision, S8b + S3a) | 3 (default branch, bare `make`, `-fPIE` link) | 0 | 4 | 2 | ~3,700 |
