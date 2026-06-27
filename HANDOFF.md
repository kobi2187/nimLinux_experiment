# HANDOFF.md — Session Exit Note

Last updated: 2026-06-27 (session 3)

## What happened this session

Resumed from session 2. Completed:
- TW#73 — testMode boot flag (marked done, was already implemented)
- TW#8  — ELF loader segment bounds check: `elfLoadOob` on overflow, tests added
- TW#3  — CPU% in ps: `abiProcList` now emits `(cpuTicks*100)/uptimeTicks` per task

Also clarified TW#4 (guard pages) is FUZZY — needs per-process page tables / CR3 switching, which isn't built yet. Real guard pages deferred; software bounds check (TW#8) is the immediate win.

## Key architectural facts

- Apps run in ring 3 via `procSpawnRing3` (iretq frame on kstack)
- ABI calls: trampoline `movabs rax,<nr>; syscall` → `syscall_entry` (boot_asm.S) → `syscallDispatch` → vtable
- `abiExit`: frees region + kills task + yields (no longer panics)
- Shell returns immediately after spawning (parallel execution)
- testMode: `make test-structured` builds `-d:testMode` kernel, runs kernel_tests (ring 0) then user_tests.elf (ring 3)
- `launchElfBytes(name, ptr, len)` in shell.nim — public API to spawn any PIE ELF from bytes
- `syscallScratchRsp` / `globalTss` are single-CPU globals (SMP plan in DECISIONS.md)

## Where to resume

**Layer 1 (CLEAR, no blockers):**
- TW#47 — PS/2 mouse driver: decode 3/4-byte protocol, publish mouse.move/click to event_server (~100 LOC in drivers/ps2_mouse.nim)

**Layer 2 (CLEAR, no blockers):**
- TW#48 — virtio-blk: replace ATA PIO diskio.c with virtio block requests (~150 LOC, same pattern as virtio-net)
- TW#49 — ARP: send/receive, maintain arp_cache[IP→MAC]

**Blocked / deferred:**
- TW#4 — guard pages: needs per-process page tables + CR3 switch on task switch (not built)
- TW#70/71 — test phase 2/3: needs boot-from-disk (Milestone 1)

## Build commands

```
make test              # host unit tests
make test-structured   # QEMU in-kernel test run (kernel + user ELFs)
make build             # all 3 kernel models
make iso && make qemu  # boot default ISO
```
