# STATE.md — Current Status

Last updated: 2026-10-25 (session 9, branch `ccr-56330414-wo65nx`)

## Just landed

- **V10 virtio-blk timeout: root-caused and fixed** (DECISIONS §V10b). Non-volatile
  CommonCfg stores were reordered by GCC (`queue_enable` before avail/used), so the
  device latched avail=used=0. All virtio-pci register access is now volatile.
  `mount` works; ELFs load from disk. Unblocks: everything on the disk path
  (exec, fs_server, dispatcher ELF, boot-from-disk open question #1).
- **Dispatcher transport pump** — `dispatchPump` (recv → actor → tick) shared by
  kmod/ELF; `tryDecodeRequest` so malformed app input no longer kills the
  dispatcher. ELF variant now runs the CPS actor (`--os:any --panics:on`); loads and
  spawns in QEMU. 15 dispatch tests green.
- **Capability first-grant bug** — first cap minted after boot was NullCap
  (`capTableInit` never called). Fixed; structured in-kernel suite **24/24**.
- **Build health** — repo builds anywhere (no `/home/kl` paths); kernel targets no
  longer go stale (`FORCE`); testMode kernel compiles again; ccfeb6d tests wired in.

## Verified this session (Nim 2.2.4, QEMU 8.2.2 TCG, OVMF)

`make test` ✅ · `make test-arc` ✅ · `make build` (3 models) ✅ · `make nim-apps` ✅ ·
`make test-structured` 24/24 ✅ · QEMU harness 5/11 (was 4/11; see sharp edges).

## Now / Next

Roadmap A–E (approved session 8b): A) reality audit + virtio-gpu boot verify →
B) rasterizer+font → GUI terminal → C) input_server + app_server skeleton →
D) media demo → E) scheduler block-on-mailbox/wake-on-deliver + dispatcher
transport wiring — network last. Session 9 work is Phase A (reality audit): it
found the disk path, ring 3 and the ABI patch table all broken in practice.

- [→] **TW#65/TW#72 ring-3 bring-up** (WIP, session 9b): `hello.elf` and `ps.elf`
  now run in ring 3, print, exit and the shell resumes. TW#72 "RIP=0x101e" was
  REAL (not stale): first switch to a ring-3 task `ret`'d to address 0. Open:
  triple fault on the 3rd consecutive app launch (RSP=0x8 → stale kstack).
- [→] casfs brainstorm (see HANDOFF §8b for full state): ecosystem survey
  blocked on web-limit, resume with namespace question 1.
- [ ] Roadmap Phase A: confirm `virtio-gpu: ready` (boot with
  `-device virtio-gpu-pci`); audit docs vs commits 4d028b9/385f410 (audio+input
  drivers exist, docs stale).
- [x] Dispatcher Stage 1 (34a3592) + transport pump (session 9). Channel
  ownership resolved: server-owned channel + receive capability (`chanCreate` /
  `capRecv`, WIP). Next: dispatcher ELF calls `nimixChanCreate("dispatch")`.
- [ ] Phase E: block-on-mailbox/wake-on-deliver — replaces the interim
  `waitForTick` (sti;hlt) in sleep/yield and the dispatcher's `nimixSleep(1)` poll.
- [ ] raylib/naylib PLATFORM_CUSTOM onto `virtioGpuFbPtr()` / `virtioGpuPresent()`.
- [ ] `fs/littlefs_wearleveling.nim` → rename to honest `ramfs` VFS lib; real
  littlefs per the Nim-ecosystem-first rule (survey nimble before vendoring C).

## Known sharp edges

- nim-cps needs `--mm:arc --panics:on` — actor/dispatch tests live in `make test-arc`.
- `qemu_harness.py` needs `--virtio-blk` to attach the disk the way the driver
  expects; its `boot` check fails spuriously (prompt consumed while waiting).
- Loader/spawn path not interrupt-safe (cli/sti scoped fix in testMode only).
- metadata_db kernel-only seq/string corruption — FAT-only mount bypass active.
- Loading a ~190 KB ELF with blk TRACE logging takes >20 s under TCG.

## Open threads (unchanged)

Dispatcher cap-gating (M2), DHCP → net_server, VFS drivers (littlefs/lwext4).
