# HANDOFF.md — Session Exit Note

Last updated: 2026-07-03 (session 8b, dispatcher Stage 1 + roadmap + casfs brainstorm OPEN)

## Session 8b — dispatcher actor, bench, roadmap reset, casfs brainstorm started

**Landed (master, all committed):**
- `ac0df07` bench: `make bench-arc` — actor deliver ~60ns, mailbox ~62ns,
  328 B/parked actor (100k scale), zero heap growth over 1M delivers.
- `34a3592` dispatch Stage 1: single-actor run loop in `dispatch_logic.nim`
  (deliver-driven: `mkRequestMsg`/`mkTickMsg`; peek-then-pop drain so
  backpressured requests keep aging). Pipeline 377 ns/req (~2.7M req/s).
  Tests 8–10 in test_dispatch_logic; ELF `-d:dispatchNoCps` build verified.
  ADRs: DECISIONS §CPS actor idiom + §Dispatcher Stage 1.

**Decisions converged with user this session:**
- Roadmap order APPROVED: A) reality audit + virtio-gpu boot verify →
  B) rasterizer+font → GUI terminal → C) input_server + app_server skeleton →
  D) media demo → E) scheduler block-on-mailbox/wake-on-deliver + dispatcher
  transport wiring (parallelizable) → network LAST.
- CPS in servers: per-server by need (net/fs/media yes eventually; input/log/
  roster stay plain loops). Continuations NEVER cross IPC boundary.
- CPU scheduler: keep simple preemptive 3-class ring; one upgrade worth doing
  = block-on-mailbox/wake-on-deliver (kills `nimixSleep(1)` polling).
- Filesystem: content-addressable store + fast queries built ON TOP of VFS
  (not a from-scratch FS). metadata_db B+tree moves to userspace fs_server
  (kills its kernel seq/string bug by relocation). Key redesign allowed.
  casfs = SPAWN candidate, but **user wants brainstorm first — IN PROGRESS.**
- NEW STANDING RULE (saved to auto-memory feedback_nim_ecosystem): scour Nim
  ecosystem (awesome-nim, GitHub, forum.nim-lang, nimble) before building;
  build-decisions must name rejected Nim libs.

**casfs brainstorm state (superpowers:brainstorming, step: context done, ecosystem survey INCOMPLETE):**
- Context read: `fs/metadata_db.nim` (382 ln, in-memory B+tree, string keys →
  uint64 fileId, 4K page serialization, probe/search split);
  `fs/vfs.nim` (92 ln prefix router); fatfs BUILT; littlefs/lwext4 stubs 44 ln.
- Proposed shape (user tentatively ok, wants to understand deeper): 3 layers in
  userspace fs_server — (1) CAS blob store, hash-named files on underlying FS,
  (2) name→hash namespace, (3) query index (B+tree, redesigned keys). Immutable
  blobs = safe zero-copy region caps. Whole-file hashing first; chunking only
  if needed.
- Ecosystem survey BLOCKED mid-run: WebSearch/WebFetch session limit (resets
  22:10 Asia/Jerusalem). Candidate libs FROM MODEL MEMORY — ALL UNCONFIRMED,
  verify on nimble/GitHub before relying: `blake3` wrappers, nim-lang/
  `checksums` (SHA2/SHA3), `nimcrypto` (pure Nim), `limdb`/`nimdbx` (LMDB/
  libmdbx wrappers), `tiny_sqlite`. Survey must also check pure-Nim vs
  C-wrapper fit for --os:standalone ELF.
- OPEN QUESTIONS to drive next brainstorm round (one at a time):
  1. Is casfs the PRIMARY namespace (everything content-addressed, git-style
     name→hash repointing on write) or a SIDE store for assets/media next to
     plain FS paths? ← most load-bearing, ask first.
  2. Mutability model apps see (rewrite = new hash + repoint vs explicit
     immutable blobs).
  3. Query semantics needed: exact tag, range, live queries (BeOS-style via
     event_server), full-text?
  4. Blob GC: refcount vs mark-sweep vs defer.

**Where to resume:** re-run ecosystem survey (web limit reset), then continue
brainstorm with question 1 above. Skill flow: superpowers:brainstorming →
design doc → writing-plans. Roadmap Phase A (gpu boot verify + doc-reality
audit — audio/input drivers exist in commits `4d028b9`/`385f410` but docs say
PLANNED) can run before/parallel to brainstorm.

## Session 8 — {.cursor.} fix, actor promoted to lib, merged to master

- Applied `{.cursor.}` to `Actor.suspended` (`runtime/actor.nim`) — ARC ref
  cycle gone (`CycleCreated` warning no longer emitted), every parked actor
  no longer leaks. Test still green.
- Added `tests/test_actor.nim` to `make test-arc` (alongside dispatch tests —
  same `--mm:arc --panics:on` class). `make test-arc` fully green.
- Regenerated STATE.md (was deleted in working tree, unexplained); updated
  ARCHITECTURE (Mailbox + Actor now BUILT; virtio-pci SPAWNED→BUILT drift);
  appended DECISIONS §CPS actor idiom ADR.
- Merged branch `experiment/actor-mailbox-cps` into `master` — actor +
  mailbox are now trunk modules other code can depend on.
- TW#72 V10 boot corruption: user says likely stale status — verify with
  `make debug-log` before treating as real (in STATE.md Next).

**Next:** design proposal for porting actor into
`servers/dispatch/dispatch_logic.nim` (priority queue + QoS integration —
cross-cutting, dialogue first).

## Session 7 — actor/mailbox CPS POC: idiomatic suspend/deliver WORKS
(branch `experiment/actor-mailbox-cps`)

## Session 7 — actor/mailbox CPS POC: idiomatic suspend/deliver WORKS

Branch: `experiment/actor-mailbox-cps` (not merged to master; commit `911314e`
on branch is the prior broken looping model — current working tree has the
fix, uncommitted).

**Task:** get a nim-cps actor (continuation that receives messages) working
without the leg-rerun/duplicate-message bugs hit in prior sessions (see
`project_memory/reference_cps_mechanics.md` for the full failure trace across
12 POCs).

**Result: PASS.** `runtime/actor.nim` now uses the idiomatic suspend/resume
pattern (mirrors nim-cps's own `examples/coroutine.nim`):
- `suspend()` is a dumb park — cpsMagic just stores `a.suspended = a` and
  returns it. Reads nothing.
- Sender plants the message into `a.pending` BEFORE calling `resume()`.
- The body reads via `recv()` (cpsVoodoo) AFTER `suspend()` returns — always
  fresh, no flags/counters, no empty-inbox path.
- Body shape: `while true: suspend(); handle(recv())`.

This sidesteps every hazard from the old looping-actor-with-internal-pop
design (stale re-processing on the 2nd `trampolineIt` break, handler leg
re-running with stale state). Root cause of the old bugs (documented in
memory): iterator (yield-out) and actor (handle-in) are duals — the
break-point that works for "pause when value ready" stops BEFORE the handler
leg for handle-in, so the handler either never ran or re-ran stale. Moving
message-consumption to happen in the body (via `recv()`), not in the magic,
removes the duality mismatch entirely.

**Verified:** `tests/test_actor.nim` — 4 sequential deliveries (42, 99, 7, 8),
correct order, no duplication, no loss. Compiled+run directly (no Makefile
target yet — this is POC-stage):
```
nim c --skipParentCfg --os:linux --mm:arc --panics:on --path:. -r \
  --nimcache:.nimcache_actor tests/test_actor.nim
```
`--path:.` is required (test imports `ipc/mailbox` relative to repo root);
omitting it fails with "cannot open file: ipc/mailbox". `--mm:arc --panics:on`
is a hard nim-cps requirement, incompatible with `--mm:refc` (the NimixOS host
default) — this test can't run under `make test`.

**Known issue, not yet fixed:** `runtime/actor.nim:32` — `a.suspended = a`
creates an uncollectable ARC ref cycle (compiler warning:
`CycleCreated`). Works today (doesn't block the test), but every parked actor
leaks under this pattern. Fix: annotate `suspended*: Actor` with `{.cursor.}`
in the type def in `runtime/actor.nim` — breaks the cycle since it's a
self-observation field, not an ownership edge. Not yet applied — flagged to
user, awaiting decision on fix-now vs. leave-as-POC-debt.

**Uncommitted working-tree state this session:** `runtime/actor.nim`,
`tests/test_actor.nim` (rewritten to new idiom), `AGENTS.md` (persona/operating
principles prepended — unrelated to actor work, pre-existing modification).
Untracked: `experiments/actor_poc/poc12.nim` (the POC that found this idiom),
`experiments/actor_poc/_probe.txt`, `run12.log`, `.actor_test.log` (empty —
were victims of a disk-full condition mid-session, since resolved), `AGENTS.bkupmd`,
`.nimcache_actor/`.

**Next step for this branch:** decide the `{.cursor.}` cycle fix, then decide
whether to port this actor into `servers/dispatch/dispatch_logic.nim` (the
CPS dispatcher — this POC's actual target per VISION.md goal #4 and
ARCHITECTURE.md's dispatcher design) or keep iterating standalone first.
`ipc/mailbox.nim` (MPSC ring, committed at `2c1484d`) is the mailbox this
actor consumes from — not modified this session.

**Aside — disk-full false alarm:** mid-session the host disk hit 96%
(9.3G/213G free) and two backgrounded `nim c` runs died silently (no output,
no completion record). Investigated: this repo is NOT the cause —
`nimixos.iso` is 9.6M (nowhere near any 500MB concern raised), `.nimcache_actor`
756K, `build/` 1.3M. Real usage is elsewhere under `/home/kl` (Android 23G,
prog 17G, apps 15G, VirtualBox VMs 13G, snap 9.4G) — unrelated to this
project. Third compile attempt run in the foreground (not backgrounded)
succeeded. **Lesson: on this host, prefer foreground `Bash` for short nim
compiles during low-disk conditions — backgrounded tasks were silently killed
twice with zero trace, foreground caught the real result immediately.**

## Session 6 — virtio-gpu PCI transport migration

Updated STATE.md to reflect reality (it was 3 sessions stale). Migrated
`virtio_gpu.nim` from the old MMIO path to the modern virtio-1.0 PCI transport.

**What changed:**
- `drivers/virtio/virtio_gpu.nim`: replaced direct `pciVirtioFind`/`pciBarDecode`
  MMIO calls with own `gGpuDev` PciMappedDev global (same pattern as `gVirtioBlk`),
  calling `virtio_pci.nim` low-level functions directly. DMA ring allocated via
  `allocDmaPages` + physical address via `translatePhys`. Commands use uncached
  `mapDeviceMmio`-mapped BAR. `virtioGpuInit` tries PCI first, falls back to old MMIO.
- `kernel/services/init.nim`: `initVirtioDevices` now calls `virtioGpuInit`.

**Done-check status:** TBD — needs `make iso && make qemu` to confirm serial shows
`virtio-gpu: ready` and QEMU window displays output.

## Where to resume

**Next task (highest leverage):**
Wire raylib/naylib into the GPU — the framebuffer pointer (`virtioGpuFbPtr()`) and
`virtioGpuPresent()` are the integration seam. `PLATFORM_CUSTOM` backend in naylib
needs a `BeginDrawing`/`EndDrawing` hook that calls `virtioGpuPresent`.
Vendors already in tree: stb_truetype, audio, pl_mpeg.

**Other open threads:**
- TW#65 — ring-3 user_tests serial truncation (Task 3 ring-3 unverified)
- Dispatcher server cap-gating (Milestone 2)
- metadata_db kernel fix (seq[string] → fixed `array[N,char]` keys)
- DHCP → net_server wiring

## Session 5 recap (for continuity)

Fixed harness bugs (qemu_harness.py prompt-wait in testMode; pid_monotonic assertion).
Spawned virtio-pci sub-project. Completed Task 2 (ELF GLOB_DAT/JUMP_SLOT/R_X86_64_64).
Completed Task 3 (nimixMapAnon/FreeAnon ABI, host-verified). V9 wired PCI into blk.
V10 DMA ring uncached fix confirmed virtio-blk(pci) works in QEMU.
Kernel refactored into core/services/boot phases. Shell made generic launcher.
VFS layer + metadata_db discovered in tree (B-tree host-tested green; kernel heap
bug with seq[string] bypassed via FAT-only mount).

## Build commands

```
make test              # host unit tests
make test-structured   # QEMU in-kernel test run
make build             # all 3 kernel models
make iso && make qemu  # boot ISO, check serial for virtio-gpu: ready
```
