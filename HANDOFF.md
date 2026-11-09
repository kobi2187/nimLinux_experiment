# HANDOFF.md — Session Exit Note

Last updated: 2026-10-27 (session 9e, branch `ccr-56330414-wo65nx`, cloud container)



## Session 9i — V2 done (picolibc), V3b decided

Human: picolibc yes (musl is heavier); apps read the clock via the lightest,
most efficient route = time page with a syscall fallback. V2: `make test-v2`
(raylib + rlsw link against picolibc needing exactly 31 OS symbols; libm
≤ 1 ULP). **Next:** V2b libnimix, V3b time page, V4 large memory; all feed V5
(raylib on NimixOS). Human's framing: the OS can be useful and innovative and
a teaching OS for OS design, so each piece gets a stated design and a test.

## Session 9h — GPU parked, V3 done, V2 blocked on a permission

PR #3 merged. GPU acceleration PARKED (VISION Q7, BACKLOG V13; human: "can do
a lot without it"). **V3 done:** TSC clock calibrated against PIT channel 2
(pure math `core/tsc_clock.nim`, host-tested against an exact 128-bit
reference; driver `drivers/tsc.nim`); QEMU: 100 PIT ticks = 999-1000 ms on
the TSC. A first run failed because my test started mid-tick (a sleep to a
tick count spans 99-100 periods), fixed by aligning to a tick edge, and
calibration jitter (host scheduling in the poll loop) is handled by a median
of 5 × 30 ms windows. **V2 is blocked:** I cloned picolibc 1.8.12 into the
scratchpad and meson-configured it, but the build was denied by the permission
classifier (code from an external repo). Ask the human to allow it, or switch
to musl. **Open decision (V3b):** how apps read the clock (read-only time page
vs `nanoTime` syscall; my pick: the page, with the syscall as fallback).

## Session 9g — vertical slice: P0 done, V7a done (RUI on the bridge, direct)

Render-server model + raylib bridge AGREED; P0 showed the command path costs
~nothing (rlsw raster dominates). V7a: RUI's counter example, unchanged,
paints headless through adapted naylib (`tools/naylib_adapt.py`) on raylib
6.2 + rlsw with a Pixie text engine (`make test-v7`). RUI changes are a
patch set in `patches/rui2/` (human: push to kobi2187/rui2 only after we
stabilize). V7b: the same app through the **remote** bridge (routing at the
C-symbol level, `bridge/rl_route.nim`) is byte-identical to direct, steady
frames ≤ 86 records / 1 KB. **Next:** V2→V5 critical path (raylib on
NimixOS), or V7c actor-backed background/mailbox.

## Session 9f — bulk data frozen, buffers spawned

The human wanted big data moved formally, with no unsafe shared memory. The
existing region "zero copy" was tested and found unsafe (three holes fixed,
see DECISIONS §Region capabilities). The bulk-data proposal went through
two rounds (v2 aligned with the dispatcher axiom, batching, budgets and WASM),
and all seven decisions were agreed. It is FROZEN as `ipc/buffers.nim` (a stub
plus layout test) and SPAWNED as `subprojects/buffers/` (first task: SURVEY).
app_server's protocol is agreed and builds on it; spawn it next. VISION Q6
is resolved: Stage A page rights now, per-app CR3 next.

## Session 9e — framebuffer console (roadmap B step 1), user-fault kill

The shell now runs on the virtio-gpu display as well as serial, and reads
keys from the QEMU window: `gfx/` (canvas, Spleen 8x16 font, UTF-8),
`term/` (VT100 subset + incremental renderer), `input/` (evdev keymap) are
pure libs; `kernel/console/` is the fbcon-style consumer. The pixel test
(`tools/term_replay.nim`: host renders the same byte stream) caught a real
race (render vs. concurrent ring-3 output) → snapshot flush. Ring-3 faults
kill only the task (DECISIONS §User-mode faults). See DECISIONS §Roadmap B.

**Next:** roadmap C — app_server owning the display (windows as region
caps), terminal app in a window reusing term/gfx; input_server.

## Session 9d — QEMU integration, virtio verified on the host, debug tooling

Human: "Improve qemu integration, virt drivers, and enable valgrind and
debugging tools, whether over serial or native." Done and verified:
`tools/nimix_qemu.py` is the single QEMU launcher (tests + `make qemu*`);
`make test-devices` checks gpu/snd/net/input by their host-side effect
(pixels, wav tone, pcap, injected keys) plus crash reports — 7/7. Six real
driver bugs fixed on the way (gpu non-volatile spin, snd spec rewrite,
64-entry queue size stated to devices, shared-INTx/ELCR/cascade, snd
completion, init order). Serial: crash report + backtrace on every CPU
exception and panic, `tools/symbolize.py`, `dmesg`. Native: `make
test-valgrind`, `make test-asan` (UBSan found a misaligned kernel stack →
fixed), `make qemu-debug` + `make gdb-attach` (tools/gdb/nimix.gdb). See
DECISIONS §QEMU integration.

**Next (roadmap B):** rasterizer + font on the verified virtio-gpu → GUI
terminal; input_server consuming topic `input` (C). Done since: ring-3
faults kill only the task (DECISIONS §User-mode faults); trap-frame register
order fixed.

## Session 9c — "make it all work": WASM apps, ELF system, every model green

Human: "Just make it all work. Regular apps are wasm, servers and system are
elf." Done and verified: 16/16 QEMU suite on all three kernel models, 41/41
structured, host + ARC + new WASM host tests. Key pieces: shell runs bare
names from disk; Nim → WASM app SDK (`apps/wasm/`, modules import only
NimixOS host calls); `cat.wasm` reads files through `fs_server.elf`;
exit/kill release everything a task owns; micro/sasos fixed (procTableInit);
kernel `--panics:on` with fatal text on serial. See DECISIONS §Apps are WASM.

**Next:** Phase A virtio-gpu verify; put the dispatcher into the app path;
larger WASM file reads; consider moving wasm3 into a userspace ELF host.

**Toolchain for a fresh container:** Nim 2.2.4 tarball; `nimble install
https://github.com/nim-works/cps msgpack4nim`; apt `qemu-system-x86 ovmf
grub-pc-bin grub-efi-amd64-bin xorriso mtools dosfstools clang lld wasi-libc
valgrind gdb`;
`pip install wasmtime`; `git submodule update --init vendor/wasm3 vendor/printf`.
Then: `make test test-arc build nim-apps wasm-apps test-wasm disk
test-structured test-qemu-models test-devices OVMF=/usr/share/ovmf/OVMF.fd`;
`make test-valgrind test-asan` for native memory checking.

## Session 9b — ring 3 end to end, decisions resolved, origin/main merged

Human set the decision principles (now in VISION): microkernel, functionality
in servers, actors + fibers, capabilities, oskit libs — no POSIX/OS threads;
basis prerequisites allowed. Resolved with them: server-owned channels via a
receive capability (`chanCreate`/`capRecv`); dispatch_kmod + kernel CPS
PARKED; littlefs_wearleveling → `ramfs`; mpsc_ring parked for SMP.

Then drove ring 3 from "nothing runs" to "41/41 structured, user_tests 17/17,
dispatcher + apps concurrent, zero faults" — eleven root causes, each found
from QEMU/gdb evidence (DECISIONS §Ring-3 bring-up). Biggest surprises: the
GDT order made SYSRET produce CS=0x2B (TSS); Nim's standalone heap was
8-byte aligned in every binary (kernel too).

Merged origin/main (your session-8b handoff) as a docs union — nothing dropped.

**Next:** Phase A virtio-gpu verify; fix `ls` (fsReadDir "/"); first real
dispatcher round trip (client → dispatch → fs); re-verify kernel strings now
that the heap is aligned; release channels/caps on server exit.

**Debug kit that found these** (scratchpad scripts, recreate as needed): drive
the serial shell from Python over QEMU stdio; `-d int,cpu_reset -D log` for
exception chains; HMP `info virtio-queue-status`; `qemu -s` + `gdb
add-symbol-file app.elf -o 0x2000000` + `hbreak` at the faulting RIP for a
backtrace. The PF handler now prints CR2.

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
