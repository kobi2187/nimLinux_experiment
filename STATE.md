# STATE.md — Current Status

Last updated: 2026-11-15 (branch `ccr-56330414-wo65nx`, synced to `master` after PR #11 merged). Earlier
states of this file are in git history; this file holds the CURRENT state only.

## Repository facts (so no session rediscovers them)
- Default branch is **`master`**; `main` is stale (14+ commits behind). Base new work on `master`.
- Work on the session branch, push only there, PRs are drafts, never merge unless the human asks.
- Toolchain: Nim 2.2.4 at `/opt/nimtc/nim-2.2.4/bin` (put it on PATH); QEMU 8.2.2 (TCG) + OVMF.
- Safe make targets: `test`, `test-devices`, `test-qemu-models`, `test-structured`, `disk-add-apps`.
  **Never bare `make`** (its default target opens an interactive QEMU).
- Gate before any push: all four test targets green, run once and alone (AGENTS.md, VERIFY). CI parity (asan, valgrind, arc, wasm) was clean on 2026-11-18; `test-v2` needs meson, absent in this container.
- Last gate (2026-11-15, head 26da1d0): `make test` pass; `test-devices` 39/39 on all three kernels; `test-qemu-models` 16/16 x3; `test-structured` 47/47.

## Awaiting human (decisions only the human can make; **unanswered means OPEN: nothing is built on a recommendation**)
| asked | question | blocks | my recommendation (NOT a decision) |
|-------|----------|--------|--------------------------------------|
| 2026-11-17 | **On a user switch, what happens to the first user's running programs**: A end them, B keep running sealed, C freeze, D (yours) save their state so they close but can resume | the session/login design; per-user budgets; the launcher's per-user token list; what a program must be able to save | undecided, left for you |
| 2026-11-17 | **What proves who logs in** (nothing, a password, a device) and where a user's token set is stored | login; the user-token file format | undecided; the foolish-user rule (a user's tokens never include the system's authority) holds either way |
| 2026-11-15 | K1 contract/IDL: how a server's API is described and how client libraries are produced | K2 dispatcher stage 2, generated client libraries | a proposal with options comes first |
| 2026-11-15 | `main` is stale: fast-forward it to `master` or delete it | nothing | fast-forward, then delete later; left as is meanwhile |
| 2026-11-15 | AGENTS.md revision is an experiment: judge it from the Process log below | nothing | revert from `docs/archive/` if it does not help |
| 2026-11-14 | S8c: language domains (checked safe Nim subset) for the SASOS model | S8c only | keep PROPOSED |

**Decided 2026-11-17 (see DECISIONS):** screen capture = Option A (held by the compositor, triggered by the user's key chord, built with the render server V6); users are a token set, several per machine, one active at a time; display ownership = handle-only (D3 option A), BUILT.

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
| 2 | three interchangeable kernel models | **strong** (2026-11-15) | the 16-test harness AND the 39-test device suite (isolation, handles, spawn, buffers, display, input) pass on monolithic, microkernel and SASOS |
| 3 | dispatcher as the QoS/concurrency hub | **weak** | Stage 1 exists but is in no app's path; K1 and K2 not started |
| 4 | CPS coroutines for servers | partial | dispatcher only |
| 5 | raylib graphics + audio | strong for direct rendering | pixel-exact on NimixOS; render server (V6) and audio server not started |
| 6 | capabilities as the only access control | **strong for input and display, partial elsewhere** | handles, rights, spawn, per-task spaces tested; keyboard/mouse (keylogger test) and the screen (overlay test) are capability-only. Still ambient: `chanSend`, the remaining event topics, the file system calls; the shell holds every right |

**2. Leaves I do on my own** (CLEAR: local, reversible, no frozen API, in this order)
1. ~~Run `test-devices` against the sasos and microkernel kernels~~ **DONE 2026-11-15: 39/39 on all three.**
2. valgrind/ASan pass on the new libraries (launcher/manifest, addr_space, arena) and the missing ones.
3. Guard pages below task stacks (the page-splitting code exists; local to `kspace`/`addr_space`).
4. R9: retire the ping/dispatch kernel modules in the microkernel model.
5. V7c: actor-backed `background`/`mailbox` behind RUI's API (threads off).
6. V4b: measure arena sizing and per-class budgets, then set them from the numbers.
7. V2c: sub-tick timer (S4).
0. ~~K3 layers 2-4~~ **DONE 2026-11-17 (result b delivered for input).** Done since: sanitizers on the new libraries, shared launch helpers, a second static-checking pass, the stack guard page (1 MB stack reserve per region). NOT independent (blocked on questions): routing PS/2 into the input port is possible but I cannot test it end to end (QEMU feeds the virtio keyboard) and it could double keys, so it waits for a way to test it.
8. **Static-checking audit** (first pass DONE 2026-11-15 on the foundation code: 2 enum catch-alls made exhaustive, 4 silent discards made assertions; still to audit: bare `int`s standing for handles/sizes/addresses outside the ABI boundary, and the older drivers/shell code). Original scope: find `case` statements over enums that end in a catch-all `else`, bare `int`s standing for handles/sizes/addresses/states, and silent `discard`s of results that can fail; fix them or add the missing compile-time checks. Local and reversible; I take it early because every later step benefits.

**3. Needs direction** (each will be asked in the question template; first = blocks the most)
- **K1 contract/IDL** (blocks K2 and every server's client library): a frozen API.
- **E1 event server**: how a subscription is a handle; a new subsystem boundary.
- **S2k-b2** fold the buffers table into the handle table: changes the frozen buffers API (logged in both projects).
- **K2 dispatcher stage 2**, **R0 device capabilities** (interrupt/MMIO/DMA as handles), **V6 render server** (12 decisions open), **V8 userspace WASM host**, **S8c language domains**.
- **`main` branch**: fast-forward or delete.

**4. Results you could see next** (you choose the focus; each is a demo you can run)
| # | what you would see | what it takes | decisions needed |
|---|--------------------|---------------|------------------|
| a | ~~**Three kernels, one table**~~ **DONE 2026-11-15**: 39/39 on monolithic, microkernel and SASOS | — | — |
| b | ~~**Keys reach only the program given the port**~~ **DONE 2026-11-17**: a keylogger beside the real client gets nothing; the `input` topic is gone (`keyboard-isolation`) | — | — |
| c | **The shell as an ordinary program**: `shell.elf` started by the launcher with only the rights its manifest grants; the kernel keeps a serial console | R5/R6 console server + userspace shell (needs b's patterns) | K3, K1 |
| d | **Two windows on screen**, overlapping, each drawn by a different app, composed by a render server; a hostile client is refused | V6 slices (needs K1, K2, K3, M1, M2) | the 12 open V6 decisions, K1, K2, K3 |
| e | **A WASM app (the RUI counter) running in a userspace host** with no WASM code in the kernel | V8 (needs K2) | V8 boundary |
| f | **Sound through an audio server** (440 Hz tone via a session) | V10 (needs K3) | K3 |

## Next in order
K1 contract/IDL → K3 device ports (then S3b removes the ambient calls) → K2 dispatcher stage 2 →
E1 event server → S2k-b2 (one handle table for every object) → V6 render-server slices.

## Process log (AGENTS.md experiment; see AGENTS.md, last section)
| session | rediscovered facts | pushes without gate | test-fault reds | human repeats | ORIENT lines | runtime-only bugs a static check could catch |
|---------|-------------------|---------------------|-----------------|---------------|--------------|------|
| 2026-11-17 (K3, display port, guard page) | 0 | 0 | 4 (spawntest's `display`, the `read` return, the wait right, isotest's offset) | 3 (never assume a decision; questions in the template; ask in plain words) | ~600 | 2 (PS/2 topics still published; a stale offset the guard exposed) |
| 2026-11-15 (before the revision, S8b + S3a) | 3 (default branch, bare `make`, `-fPIE` link) | 0 | 4 | 2 | ~3,700 | 3 (free RAM starved by static growth; channel-read return convention; right missing on a handle) |
