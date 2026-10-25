# HANDOFF.md — Session Exit Note

Last updated: 2026-10-25 (session 9, branch `ccr-56330414-wo65nx`, cloud container)

## Session 9 — V10 root cause, dispatcher pump, cap + build fixes

Fresh container had no toolchain; installed Nim 2.2.4, nim-cps 0.11.4,
msgpack4nim 0.4.4, QEMU 8.2 + OVMF + grub/xorriso/mtools/dosfstools. First full
QEMU verification in months showed the disk path dead: every virtio-blk(pci)
request timed out. QEMU's own view (`info virtio-queue-status`) showed the device
held avail=used=0; disassembly showed GCC moved the `queue_enable` store ahead of
the avail/used stores. Fix: volatile access for all virtio-pci registers
(DECISIONS §V10b). Disk mounts, ELFs load.

Also: dispatcher `dispatchPump` + strict `tryDecodeRequest` (a malformed app
message used to be a fatal AssertionDefect); dispatcher ELF now runs the CPS actor
via `--os:any`; first-capability-is-NullCap bug fixed (structured suite 24/24);
repo-relative vendor paths; kernel Make targets no longer stale; testMode kernel
compiles again; ccfeb6d's three orphan tests wired into make targets.

**Next (highest leverage):** TW#65 — ring-3 apps never run and the shell stops
answering after the first ring-3 spawn. It is now the single blocker behind every
remaining QEMU harness failure and behind observing the dispatcher ELF actually run.
Then dialogue: how the `"dispatch"` channel gets created (ABI `chanCreate` vs kernel
pre-registration) and whether the kernel build takes `--panics:on` for dispatch_kmod.

**Repro setup in a fresh container:** Nim tarball from nim-lang.org on PATH;
`nimble install https://github.com/nim-works/cps msgpack4nim`;
`git submodule update --init vendor/wasm3 vendor/printf` (vendor/arsenal has no
.gitmodules entry); `make iso disk`, then
`python3 tests/qemu_harness.py --iso nimixos.iso --bios /usr/share/ovmf/OVMF.fd --disk disk.img --virtio-blk`.

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
