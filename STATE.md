# STATE.md — Current Status

Last updated: 2026-10-26 (session 9c, branch `ccr-56330414-wo65nx`)

## Just landed — "make it all work"

- **Regular apps are WASM, system tools + servers are ELF** (DECISIONS §Apps are
  WASM). Nim → WASM SDK in `apps/wasm/` (`hello`, `cat`); the shell runs any
  bare name from disk (`name` / `name.elf` / `name.wasm`) with args.
- **App → server → disk works end to end**: `cat notes.txt` (WASM, CapIpc) →
  `fs_server` (ELF, owns `fs`) → VFS → FatFs → virtio-blk → event reply.
- **Lifecycle**: exit and kill release region, channels, caps, subscriptions —
  servers restart cleanly; duplicate servers are refused.
- **All three kernel models** pass the same suite (procTableInit was
  monolithic-only). Kernel builds `--panics:on`; fatal errors print on serial.
- CI workflow rewritten to mirror the verified local pipeline.

## Verified (Nim 2.2.4, QEMU 8.2.2 TCG, OVMF)

`make test` ✅ · `make test-arc` ✅ · `make test-wasm` ✅ · `make build` ✅ ·
`make test-structured` **41/41** · `make test-qemu-models` **16/16 × 3 models**.

## Now / Next

Roadmap A–E (approved 8b): A) reality audit + virtio-gpu verify → B) rasterizer
+ font → GUI terminal → C) input_server + app_server → D) media demo → E)
block-on-mailbox/wake-on-deliver + dispatcher transport — network last.

- [ ] Phase A: virtio-gpu boot verify (`-device virtio-gpu-pci`).
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
