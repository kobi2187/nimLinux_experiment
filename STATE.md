# STATE.md — Current Position

Last updated: 2026-06-26

## Milestone status

| Milestone | Status | Notes |
|-----------|--------|-------|
| 0 — Kernel foundation | **DONE** | Boot, scheduler, context switch, FPU, sleep, ELF loader, region allocator, capability tokens |
| 1 — IPC + services foundation | **IN PROGRESS** | MsgPack wired into ServerChan (done); fs_server ELF exists but boot-from-disk wiring incomplete; CI workflow added |
| 2 — Dispatcher server (CPS) | **PARTIAL** | dispatch_server.elf exists in build/apps; CPS logic partial; cap-gating not yet enforced |
| 3 — Zero-copy bulk data | **PARTIAL** | Region allocator done; capGrantRegion / regionAddRef/DecRef not yet implemented |
| 4 — Stdlib + compiler target | **PARTIAL** | fd table done, write(2) shim done, osalloc done; --os:nimix target not yet |
| 5+ — GUI, network, audio | **PLANNED** | virtio-gpu driver file exists; framebuffer init incomplete |

## Current frontier: what's unblocked at the lowest layer

**Layer 0 (execute now):**
- TW#48 — Syscall gate: all apps run ring 0; ABI vtable dispatch is a no-op. Fix: real ring-3 entry, 23-call vtable dispatch.
- TW#37 — CI: no automated build/test pipeline yet.

**Layer 1 (ready once layer 0 done, or in parallel):**
- TW#49 — PS/2 mouse driver
- TW#50 — RTC driver

## Recently completed (this session baseline)

- MsgPack wired into ServerChan (`serverMsgFromMp` / `serverMsgToMp`) — commit fdab067
- GitHub Actions CI workflow added — commit 258f695
- virtio-net driver + Ethernet/IPv4/UDP stack — commit 3862788
- Raylib/naylib strategy documented in DECISIONS.md — commit b3e3ffd

## What each completion unblocks

| Completed | Unblocks |
|-----------|---------|
| Syscall gate (TW#48) | Real ring-3 app isolation; all app-facing ABI becomes trustworthy |
| CI (TW#37) | Regressions caught automatically; safe to move faster |
| PS/2 mouse (TW#49) | input_server, GUI input routing, raylib input wiring |
| RTC (TW#50) | File timestamps, wall-clock time in apps |
| virtio-blk (TW#51) | Replace ATA PIO; faster disk I/O path |
| Guard pages (TW#4) | Memory safety baseline for all app regions |
| fs_server boot wiring | Boot-from-disk for all servers; resolves open question #1 |
| dispatch cap-gating (TW#32) | All I/O serialised through dispatcher; invariant enforced |
