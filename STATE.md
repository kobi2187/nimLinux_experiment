# STATE.md — Current Status

Last updated: 2026-10-26 (session 9b, branch `ccr-56330414-wo65nx`)

## Just landed

- **Ring 3 works end to end** (DECISIONS §Ring-3 bring-up — 11 root causes).
  TW#65 and TW#72 closed. Apps, servers and the shell share the CPU; apps
  allocate from their own region; the shell resumes after every app.
- **Server-owned channels by capability** — `chanCreate`/`capRecv`; the
  dispatcher ELF owns `dispatch` and runs alongside apps; a second instance is
  refused the name.
- **Heap alignment** fixed in every binary (likely root of the kernel
  "seq/string corruption" sharp edge) — guarded by `tests/check_heap_alignment.sh`.
- Decision principles recorded in VISION (microkernel, actors/fibers, caps,
  oskit libs, no OS threads); the four 2026-10-25 open calls resolved.
- Merged `origin/main` (session 8b handoff: roadmap A–E, casfs brainstorm).

## Verified (Nim 2.2.4, QEMU 8.2.2 TCG, OVMF)

`make test` ✅ · `make test-arc` ✅ · `make build` (3 models) ✅ · `make nim-apps` ✅ ·
`make test-structured` **41/41** (kernel 24 + user_tests 17 in ring 3) ·
QEMU harness **10/11** (the 1 is the harness's own boot-prompt quirk).

## Now / Next

Roadmap A–E (approved 8b): A) reality audit + virtio-gpu verify → B) rasterizer
+ font → GUI terminal → C) input_server + app_server → D) media demo → E)
block-on-mailbox/wake-on-deliver + dispatcher transport — network last.

- [ ] Phase A: virtio-gpu boot verify (`-device virtio-gpu-pci`, expect
  `virtio-gpu: ready`); audit docs vs 4d028b9/385f410 (audio/input drivers).
- [ ] `ls` → `nimixFsReadDir("/")` fails (FS/VFS path handling) — first thing
  an app hits on the disk path.
- [ ] Re-verify kernel strings/seqs now that theHeap is aligned (metadata_db
  FAT-only bypass may be removable).
- [ ] Release a server's channel + capabilities when it exits.
- [ ] Dispatcher: first real client → `dispatch` → `fs` round trip in QEMU.
- [→] casfs brainstorm (HANDOFF §8b): ecosystem survey, then namespace question 1.
- [ ] Phase E: block-on-mailbox replaces interim `waitForTick` + `nimixSleep(1)` polling.

## Known sharp edges

- nim-cps needs `--mm:arc --panics:on`; actor/dispatch tests in `make test-arc`.
- Interim: all apps share one address space (per-region User windows); per-app
  CR3 is VISION open question 6.
- `qemu_harness.py` needs `--virtio-blk`; its `boot` check fails spuriously.
- Loader/spawn path not interrupt-safe (cli/sti scoped fix in testMode only).
- metadata_db kernel-only seq/string corruption — FAT-only mount bypass active
  (re-verify after heap alignment fix).
- Loading a ~150 KB ELF with blk TRACE logging takes >20 s under TCG.
