# STATE.md — Current Position

Last updated: 2026-06-27 (session 5)

## Session 5 — boot-from-disk verification + virtio transport spawn

Executing the `2026-06-27-fs-elf-heap.md` plan inline. Task 1 (boot fs_server
from disk) code was already present in the tree. Verifying its done-check exposed
a chain of issues, fixed in order:

1. **Harness bug (FIXED):** `make test-structured` waited for the shell prompt,
   which testMode never prints (it halts after tests). Now skips prompt-wait in
   `--structured` mode → `tests/qemu_harness.py`.
2. **Disk not attached (FIXED):** test-structured passed no disk. Added a
   `--virtio-blk` harness flag (`-drive if=none + -device virtio-blk-pci`) and
   wired `test-structured` to attach `disk.img` (which has fs_server.elf).
3. **pid_monotonic test wrong (FIXED):** asserted new pid `> nextPid` (impossible —
   new pid EQUALS captured nextPid). Corrected to `pid_assigned`(==) +
   `pid_monotonic`(nextPid advanced). Kernel tests now **24/24**.
4. **virtio-blk transport mismatch (SPAWNED):** driver is MMIO-only; QEMU device is
   virtio-blk-pci → "BAR0 not MMIO". Root cause = transport mismatch, not a logic
   bug. Spawned `subprojects/virtio-pci/` behind a frozen `VirtioTransport` vtable
   (`drivers/virtio/virtio_transport.nim`, stubbed). See DECISIONS 2026-06-27.

**Task 1 status:** code correct, but boot-from-disk done-check is BLOCKED on the
virtio-pci sub-project (disk can't mount until the PCI transport lands).

**Task 2 (ELF relocs):** DONE + committed (05d9544). Verified: 7 host tests, 3 models
build, and confirmed live — testMode serial shows `PT_INTERP stripped` +
`applied relocations, count=47` loading user_tests.elf.

**Task 3 (mapAnon/freeAnon):** DONE + committed (22002c4), HOST-verified (syscall
table 26/26, all host tests, 3 models). **Ring-3 QEMU verification OPEN (TW#65):**
testMode serial truncates mid-ABI-patch right after `kernel_tests 24/24 DONE`; the
user_tests ring-3 phase (`abi_map_anon`) not observed reaching appMain. Unknown
whether real hang vs serial-flush/timeout artifact.

**TW#24 (osenv stub):** CLOSED as obsolete — survey showed msgpack4nim already
compiles + round-trips under --os:standalone, no getenv stub needed (DECISIONS).

**virtio-pci sub-project (the keystone — gates BOTH boot-from-disk AND graphics,
since virtio-blk and virtio-gpu share the MMIO-vs-PCI transport blocker):**
- V1 survey + V2 structs committed (0842b7b); V3–V8 internals committed (fa25602).
- DONE (host-tested, 11 assertions): cap-walk, capAddr, commonNegotiate,
  commonQueueSetup, notifyAddr, deviceConfigRead32 — all in `drivers/virtio/virtio_pci.nim`.
- REMAINING: V9 (wire transport into virtio_blk via VirtioTransport vtable;
  build the pciConfigReadU8/pciBarDecode adapters; verify MMIO region mapped
  uncached for volatility) + V10 (QEMU boot proof). See `subprojects/virtio-pci/STATE.md`.
- After V10: migrate virtio-gpu onto the vtable → display lights up.

## Milestone status

| Milestone | Status | Notes |
|-----------|--------|-------|
| 0 — Kernel foundation | **DONE** | Boot, scheduler, context switch, FPU, sleep, ELF loader, region allocator, capability tokens |
| 1 — IPC + services foundation | **IN PROGRESS** | MsgPack wired into ServerChan; CI workflow; fs_server ELF exists but boot-from-disk wiring incomplete |
| 2 — Dispatcher server (CPS) | **PARTIAL** | dispatch_server.elf exists; CPS logic partial; cap-gating not yet enforced |
| 3 — Zero-copy bulk data | **PARTIAL** | Region allocator done; capGrantRegion / regionAddRef/DecRef not yet implemented |
| 4 — Stdlib + compiler target | **PARTIAL** | fd table, write(2) shim, osalloc done; --os:nimix target not yet |
| 5+ — GUI, network, audio | **PLANNED** | virtio-gpu driver file exists; framebuffer init incomplete |

## Completed this session (session 4)

- TW#45 — PS/2 mouse driver: `drivers/ps2_mouse.nim`, IRQ12, 3-byte protocol decode, `mouse.move`/`mouse.click` events, 6 host tests
- TW#46 — virtio-blk driver: `drivers/virtio/virtio_blk.nim`, 3-descriptor chain, sync read/write, struct layout tests
- TW#47 — ARP: `drivers/net/arp.nim`, encode/decode, arp_cache, `arpHandleFrame`, `arpBuildRequest/Reply`, 6 host tests

## Completed in prior sessions

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

**Layer 2 (CLEAR, no blockers):**
- TW#3  — Guard pages: needs per-process page tables + CR3 switch (FUZZY, deferred)
- TW#5  — mmap-style ABI: `nimixMapAnon(size)` (FUZZY)

**Layer 3 (CLEAR, no blockers):**
- TW#2  — ELF GLOB_DAT + JUMP_SLOT relocations (enables dynamic linking)
- TW#24 — stdlib shim: `osenv.nim` stub getenv/putenv

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
