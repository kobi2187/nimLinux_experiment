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
- [→] Phase B step 2 / C: app_server API PROPOSED (docs/proposals/app_server_api.md) — awaiting agreement before freezing; then K1–K3 kernel prerequisites, SPAWN app_server.
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
