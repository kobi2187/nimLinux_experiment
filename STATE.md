# STATE.md — Current Status

Last updated: 2026-07-03 (session 8, actor merge to master)

## Just landed

- **CPS actor primitive** (`runtime/actor.nim` + `tests/test_actor.nim`) —
  idiomatic suspend/plant/resume; `{.cursor.}` on the self-ref kills the ARC
  leak. Test in `make test-arc`. See DECISIONS §CPS actor idiom (2026-07-03).
  Unblocks: dispatcher CPS run loop (`servers/dispatch/dispatch_logic.nim`)
  can now be built on actor + `ipc/mailbox.nim` (MPSC ring, 2c1484d).
- **virtio PCI transport** effectively BUILT — blk/gpu/net migrated (4d028b9).
  ARCHITECTURE table updated from SPAWNED.

## Now / Next

- [x] Dispatcher Stage 1: single-actor run loop in `dispatch_logic.nim`
  (deliver-driven; peek-then-pop drain preserves aging under backpressure).
  Bench: 377 ns/req pipeline. Tests 8–10 in test_dispatch_logic. Unblocks:
  transport wiring (kmod/elf deliver on chan recv + tick).
- [→] Wire dispatcher actor into kmod/elf transports (taskwarrior task added).
- [ ] Verify TW#72 V10 boot corruption status (RIP=0x802/0x101e after
  dispatcher init) — **likely stale per user (2026-07-03); verify with
  `make debug-log` / `make debug-gdb` before treating as real.** Blocks open
  question #1 (boot-from-disk) if real.
- [ ] virtio-gpu done-check: `make iso && make qemu`, confirm serial
  `virtio-gpu: ready` (session 6 migration unverified).
- [ ] raylib/naylib PLATFORM_CUSTOM wiring onto `virtioGpuFbPtr()` /
  `virtioGpuPresent()` seam.

## Known sharp edges

- nim-cps needs `--mm:arc --panics:on` — actor/dispatch tests live in
  `make test-arc`, not `make test` (refc).
- Loader/spawn path not interrupt-safe (cli/sti scoped fix in testMode only).
- metadata_db kernel-only seq/string corruption — FAT-only mount bypass active.
- Ring-3 user_tests don't execute after spawn (TW#65 thread).

## Open threads (unchanged)

Dispatcher cap-gating (M2), DHCP → net_server, VFS drivers (littlefs/lwext4).
