# STATE.md — Current Status

Last updated: 2026-10-27 (session 9e, branch `ccr-56330414-wo65nx`)

## Just landed — roadmap B step 1: graphics libs + framebuffer console (session 9e)

- `gfx/` canvas + Spleen 8x16 bitmap font, `term/` VT100 subset + incremental
  renderer, `input/` evdev keymap — pure libraries, host-tested.
- Kernel framebuffer console: everything on serial also shows on the
  virtio-gpu display; the shell takes keys from the QEMU window
  (`make qemu-gui`). Verified pixel-exact against a host replay.
- Ring-3 faults kill only the task; trap-frame register order fixed.

## Just landed — QEMU integration + debugging (session 9d)

- **One QEMU launcher** `tools/nimix_qemu.py` (devices, gdb, QMP, log, pcap,
  wav) behind every test and `make qemu|qemu-gui|qemu-debug`.
- **virtio gpu/snd/net/input verified on the host** — `make test-devices`.
  Fixed: gpu response wait, snd spec rewrite + completion, 64-entry queues
  stated to devices, shared PCI IRQ lines (cascade, ELCR, INTx-disable).
- **Serial debugging**: crash report + backtrace for all CPU exceptions and
  panics → `tools/symbolize.py`; `dmesg` klog ring; `devtest crash-*`.
- **Native debugging**: `make test-valgrind`, `make test-asan` (clean;
  fixed misaligned kernel stack), `make gdb-attach` with nimix-* helpers.

## Earlier — "make it all work" (session 9c)

- Regular apps WASM, system tools + servers ELF; `cat` (WASM) → fs_server
  (ELF) → FAT → virtio-blk; exit/kill cleanup; all three models pass.

## Verified (Nim 2.2.4, QEMU 8.2.2 TCG, OVMF)

`make test` ✅ · `test-arc` ✅ · `test-valgrind` ✅ · `test-asan` ✅ ·
`test-wasm` ✅ · `test-devices` **11/11** · `test-structured` **41/41** ·
`test-qemu-models` **16/16 × 3 models**.

## Now / Next

Roadmap A–E (approved 8b): A) reality audit + virtio-gpu verify → B) rasterizer
+ font → GUI terminal → C) input_server + app_server → D) media demo → E)
block-on-mailbox/wake-on-deliver + dispatcher transport — network last.

- [x] Phase A: virtio-gpu verified (screendump pixels) — plus snd/net/input.
- [x] Phase B step 1: rasterizer + font + VT → framebuffer console (shell on screen, keyboard).
- [x] Bulk-data API FROZEN (`ipc/buffers.nim`, spec docs/proposals/bulk_data.md v2); `subprojects/buffers` SPAWNED (first task: SURVEY). VISION Q6 resolved.
- [→] buffers sub-project: B1 SURVEY ✅, B2 ownership state machine ✅, B3 arena ✅, B4 session rings ✅, B5 Stage A enforcement live ✅ (ring-3 violations fault and kill only that task; `buftest` in `make test-devices`); next SASOS/mono enforcement, ring + WASM ABI, fs_server lent buffers → enforcement → ABI/WASM.
- [ ] SPAWN app_server on top of buffers (protocol agreed, freeze at spawn).
- [→] Residency migrations R0–R10 (BACKLOG; ARCHITECTURE residency map): historical kernel components to their proper homes; R0 device caps unblocks the drivers.
- [x] P0 host loopback: bridge (`bridge/`, raylib 6.2 + rlsw headless) remote pixels == direct; steady frame 19 records / 424 B; command path ≈ noise (~7%), rlsw raster dominates → damage-limited compositing first (`make test-p0`).
- [x] V7a: RUI's counter example, unchanged, runs headless on the bridge's direct backend: adapted naylib (`tools/naylib_adapt.py`) → raylib 6.2 + rlsw; Pixie text engine behind a new RUI text-engine seam; `ruiNoGlfw` (`make test-v7`; RUI changes in `patches/rui2/`).
- [x] V7b: RUI's counter, unchanged, through the **remote** bridge (draw calls → commands → loopback server): pixels byte-identical to direct after 3 clicks; steady frames ≤ 86 records / 1 KB (`make test-v7`).
- [x] V3: fine clock — TSC calibrated against PIT channel 2 (`core/tsc_clock.nim`, `drivers/tsc.nim`); 100 PIT ticks = 999-1000 ms on the TSC; structured suite 47/47 (+6), 3 models 16/16. App exposure (V3b) needs a decision.
- [x] V2: libc/libm = picolibc 1.8.12 (`vendor/picolibc`, `make test-v2`): raylib + rlsw link against it needing exactly 31 OS-layer symbols; libm ≤ 1 ULP over 7,600 samples. Next V2b (libnimix, the OS layer under it).
- [x] V3b decided (human): read-only time page + syscall fallback.
- [x] V4: large memory = buffers (a server's heap is one owned arena buffer): `buftest big` creates, touches and verifies 32 MB from ring 3; budget enforced and returned (`make test-devices` 17/17). Sizing (arena, per-class budgets) deferred to measurements (V4b).
- [→] Vertical slice raylib + RUI2 (BACKLOG V1–V13): next V7c (actor-backed background/mailbox), V4, then V5 (needs V2).
- [x] Region capability holes fixed (any-task minting, use-after-free on owner exit, leaked caps) — tests/test_zerocopy.nim.
- [x] User-mode CPU faults kill the task (system continues); kernel faults halt.
- [ ] Dispatcher in the app path: apps → `dispatch` → servers (today WASM apps
  talk to servers directly; route via dispatcher with QoS + cap-gating, M2).
- [ ] Larger file reads for WASM apps (region caps into linear memory, or
  chunked replies) — fs replies are ≤508 B inline today.
- [ ] Re-verify kernel strings/seqs with the aligned heap (metadata_db bypass).
- [→] casfs brainstorm (HANDOFF §8b): ecosystem survey, namespace question 1.
- [ ] Phase E: block-on-mailbox replaces interim `waitForTick` + server polling.

## Known sharp edges

- WASM apps run in the in-kernel wasm3 interpreter (shell context); moving the
  runtime into a userspace ELF host is the microkernel-pure follow-up.
- All ELF apps share one address space (per-region User windows); per-app CR3
  is VISION open question 6.
- `cat` after a server dies waits the full 5 s event timeout.
- Loader/spawn path not interrupt-safe (cli/sti scoped fix in testMode only).
- nim-cps needs `--mm:arc --panics:on`; actor/dispatch tests in `make test-arc`.
