# STATE.md — Current Position

Last updated: 2026-06-26 (session 2)

## Milestone status

| Milestone | Status | Notes |
|-----------|--------|-------|
| 0 — Kernel foundation | **DONE** | Boot, scheduler, context switch, FPU, sleep, ELF loader, region allocator, capability tokens |
| 1 — IPC + services foundation | **IN PROGRESS** | MsgPack wired into ServerChan; CI workflow; fs_server ELF exists but boot-from-disk wiring incomplete |
| 2 — Dispatcher server (CPS) | **PARTIAL** | dispatch_server.elf exists; CPS logic partial; cap-gating not yet enforced |
| 3 — Zero-copy bulk data | **PARTIAL** | Region allocator done; capGrantRegion / regionAddRef/DecRef not yet implemented |
| 4 — Stdlib + compiler target | **PARTIAL** | fd table, write(2) shim, osalloc done; --os:nimix target not yet |
| 5+ — GUI, network, audio | **PLANNED** | virtio-gpu driver file exists; framebuffer init incomplete |

## Completed this session (session 2)

- TW#37 — CI workflow (marked done, already existed)
- TW#50 — RTC driver: `drivers/rtc.nim`, ABI `wallClock`/`uptimeSecs`, tests
- TW#48 → A+B+C+D — Full syscall gate:
  - A: `syscall_entry` asm stub in `boot_asm.S` (stack swap, dispatch, sysretq)
  - B: `NimixSyscall` enum (24 entries), `syscallTable[]`, `syscallDispatch`
  - C: `procSpawnRing3` iretq frame; `abiExit` proper cleanup; `runPieElf` spawns + returns
  - D: ELF trampoline emits `movabs rax,<nr>; syscall` instead of `jmp <fn>`
- Orchestration framework: VISION/ARCHITECTURE/BACKLOG/STATE/HANDOFF + project_memory/
- Test infrastructure:
  - `tests/test_protocol.nim` — structured serial output (TEST PASS/FAIL/DONE)
  - `qemu_harness.py --structured` — parses protocol, exits 0/1 for CI
  - `tests/kernel_tests/main.nim` — ring-0 test ELF (11 tests: region/cap/proc/chan/tick)
  - `tests/user_tests/main.nim` — ring-3 PIE ELF (7 tests: full syscall ABI)
  - `make test-structured` — builds testMode kernel, boots in QEMU, runs both ELFs

## Key architectural facts for next session

- Apps run in ring 3 via `procSpawnRing3` (iretq frame on kstack)
- ABI calls go: trampoline `syscall` → `syscall_entry` (boot_asm.S) → `syscallDispatch` → vtable
- `abiExit` properly frees region + kills task + yields (no longer panics)
- Shell returns immediately after spawning an app (parallel execution)
- testMode: `-d:testMode` + `make test-structured` runs kernel_tests then user_tests
- `syscallScratchRsp` and `globalTss` are single-CPU globals (SMP migration plan in DECISIONS.md)
- `launchElfBytes()` in shell.nim is the public API to spawn a PIE ELF from bytes

## Current frontier: what's unblocked

**Layer 1 (CLEAR, no blockers):**
- TW#47 — PS/2 mouse driver (~100 LOC, decode 3/4-byte protocol, publish events)
- TW#3  — ps/stats: show real CPU% from PIT ISR

**Layer 2 (CLEAR, no blockers):**
- TW#4  — Guard pages: unmapped page before/after each app region
- TW#48 — virtio-blk: replace ATA PIO diskio.c with virtio block requests
- TW#49 — ARP: send/receive, maintain arp_cache

**Test infrastructure remaining (layer 1/2):**
- TW#73 — testMode boot flag (done structurally; `make test-structured` exists)

## What each completion unblocks

| Completed | Unblocks |
|-----------|---------|
| PS/2 mouse (TW#47) | input_server, GUI input routing, raylib input wiring |
| Guard pages (TW#4) | Memory safety baseline for all app regions |
| virtio-blk (TW#48) | Faster disk I/O; virtio pattern for virtio-sound |
| ARP (TW#49) | DHCP, then net_server, then dispatcher net integration |
| fs_server boot wiring | Boot-from-disk for all servers; resolves VISION open question #1; enables test phase 2 |
| dispatch cap-gating (TW#32) | All I/O serialised through dispatcher; invariant enforced |
