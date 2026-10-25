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

- [ ] **TW#65 — ring-3 apps don't run / shell hangs after first ring-3 spawn.**
  Now the top blocker: `hello.elf` prints nothing, and the next shell command after
  any `exec` gets no reply. Every harness failure cascades from this.
- [ ] Dispatcher channel ownership (cross-cutting — dialogue): `chanCreate` ABI vs
  kernel pre-registration of `"dispatch"`. Without it the ELF dispatcher idles.
- [ ] virtio-gpu done-check: boot with `-device virtio-gpu-pci`, expect
  `virtio-gpu: ready` (now plausible after V10b).
- [ ] raylib/naylib PLATFORM_CUSTOM onto `virtioGpuFbPtr()` / `virtioGpuPresent()`.
- [ ] Human call: `fs/littlefs_wearleveling.nim` — keep as VFS test double or delete.

## Known sharp edges

- nim-cps needs `--mm:arc --panics:on` — actor/dispatch tests live in `make test-arc`.
- `qemu_harness.py` needs `--virtio-blk` to attach the disk the way the driver
  expects; its `boot` check fails spuriously (prompt consumed while waiting).
- Loader/spawn path not interrupt-safe (cli/sti scoped fix in testMode only).
- metadata_db kernel-only seq/string corruption — FAT-only mount bypass active.
- Loading a ~190 KB ELF with blk TRACE logging takes >20 s under TCG.

## Open threads (unchanged)

Dispatcher cap-gating (M2), DHCP → net_server, VFS drivers (littlefs/lwext4).
