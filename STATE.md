# STATE.md — Current Status

Last updated: 2026-07-16 (session 9, Phase A: gpu boot verified + doc audit)

## Just landed

- **Roadmap Phase A DONE**: virtio-gpu boot verified — serial shows
  `virtio-gpu(pci): ready` once the device is attached; root cause of earlier
  "not found" was QEMU cmdline (no `-device virtio-gpu-pci`), not the driver.
  Makefile qemu/qemu-all/qemu-gui/qemu-debug now attach `$(GPU_DEVICE)`.
  Doc audit: ARCHITECTURE updated — virtio gpu/snd/input BUILT (4d028b9),
  audio_server PARTIAL (385f410), mpsc_ring + littlefs wear-leveling landed
  unwired (ccfeb6d). Note: `build/kernel-%` has no source deps — force rebuild
  with `rm build/kernel-monolithic` when sources change.

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
- [→] casfs brainstorm (see HANDOFF for full state): ecosystem survey blocked
  on web-limit, resume with namespace question. Roadmap A–E approved:
  gpu verify → rasterizer/font → GUI terminal → input/app_server → media →
  scheduler block/wake — network last.
- [x] Roadmap Phase A: gpu boot verified + doc audit (2026-07-16, see Just landed).
  Audit also found BUILT-but-undocumented: ps2_mouse (TW#49), rtc (TW#50),
  arp/dhcp/font_render (untested, 20b52b8) — Layer 1 effectively done.
- [x] Dispatcher ELF transport wired: `dispatchPump` in dispatch_logic
  (recv→ingest→tick→drain, test 11); ELF main loop pumps; kernel pre-creates
  well-known channels (dispatch/fs/net/media/input/log) in initIPC. Boot
  verified: `Well-known channels created` on serial. Remaining: kmod variant
  (TW#28) + end-to-end app→dispatch→fs_server test (TW#33, needs fs_server
  channel wiring).
- [→] Roadmap Phase B: software rasterizer + font onto `virtioGpuFbPtr()` seam
  (TW#60/#61), then GUI terminal.
- [ ] Wire dispatcher actor into kmod/elf transports (taskwarrior task added).
- [ ] Verify TW#72 V10 boot corruption status (RIP=0x802/0x101e after
  dispatcher init) — **likely stale per user (2026-07-03); verify with
  `make debug-log` / `make debug-gdb` before treating as real.** Blocks open
  question #1 (boot-from-disk) if real.
- [x] virtio-gpu done-check: `virtio-gpu(pci): ready` confirmed (2026-07-16).
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
