# STATE.md — Current Position

Last updated: 2026-07-01 (session 6)

## Session 6 — virtio-gpu PCI transport migration

Picking up after session 5 which left virtio-pci V10 partially done. Since then
(sessions 5b+): V10 DMA fix landed, kernel modularized, shell generified.

## What landed between sessions 5 and 6 (already committed)

| Commit | What |
|--------|------|
| d2a68a5 | V10 DMA fix: map DMA ring uncached via `mapDeviceMmio` → `virtio-blk(pci): ready` confirmed in QEMU |
| e1760d0 | V9: PCI transport vtable wired into virtio_blk |
| 5067f58 | main.nim refactored to use module loader |
| d1aa8e5 | Kernel modularity: frozen module ABI + registry |
| 0145dba | Nim quality pass across core modules |
| c6d7425 | Kernel architecture refactor: core / services / boot phases |
| 9173725 | Boot-time fs_server removed; `mount` is now a shell command |
| 876f5f5 | Shell generified: unknown command → tries `.elf`/`.wasm` from disk |
| ddc5959 | DHCP client + stb_truetype integration |
| 4ee7944 | vendor: audio (dr_libs, stb_vorbis) + video (pl_mpeg) + fonts |

## Milestone status

| Milestone | Status | Notes |
|-----------|--------|-------|
| 0 — Kernel foundation | **DONE** | Boot, scheduler, context switch, FPU, ELF loader, region allocator, capability tokens |
| 1 — IPC + services foundation | **DONE** | MsgPack wired; boot-from-disk works; `mount` shell command; shell generic launcher; fs_server.elf disk-loadable |
| 2 — Dispatcher server (CPS) | **PARTIAL** | dispatch_server.elf exists; CPS logic partial; cap-gating not yet enforced |
| 3 — Zero-copy bulk data | **PARTIAL** | Region allocator done; capGrantRegion / regionAddRef/DecRef not yet implemented |
| 4 — Stdlib + compiler target | **PARTIAL** | fd table, write(2) shim, osalloc done; --os:nimix target not yet |
| 5 — GUI | **IN PROGRESS** | virtio-gpu driver written (MMIO); needs PCI transport + init wiring |
| 6 — Network | **PARTIAL** | DHCP client added; virtio-net driver exists; net_server not yet |
| 7 — Audio/media | **PARTIAL** | vendors in tree (dr_libs, stb_vorbis, pl_mpeg); no driver yet |

## Current work (session 6)

### Task 1: Update docs (this file + HANDOFF.md) ✓
### Task 2: Migrate virtio_gpu to PCI transport [→]

`virtio_gpu.nim` currently uses the old direct `pciVirtioFind`/`pciBarDecode` MMIO
path (same bug that blocked virtio-blk V10). The PCI vtable is generic but
`virtio_pci_transport.nim` has a module-global `gDev` that can only hold one device.
Solution: gpu driver owns its own `gGpuPciDev` — same pattern as blk owning
`gVirtioBlk`. Calls low-level `virtio_pci.nim` functions directly (no shared global).

After migration: wire `virtioGpuInit()` into `kernel/services/init.nim::initVirtioDevices`.

Done-check: serial shows `virtio-gpu: ready` and QEMU display window shows output.

## Open VISION questions — status

| # | Status |
|---|--------|
| 1 | Boot disk sequence: **RESOLVED** — shell `mount` command loads servers generically from disk |
| 2 | Dispatcher IST vs PIT: open, no new signal |
| 3 | FlatBuffers schema ownership: open, not yet started |
| 4 | Rump kernel hypercall integration: open, deferred |
| 5 | SMP CpuLocal struct: open, deferred |

## Key architectural facts

- Apps run ring 3 via `procSpawnRing3` (iretq frame on kstack)
- ABI: trampoline `syscall` → `syscall_entry` (boot_asm.S) → `syscallDispatch` → vtable (26 entries)
- `abiExit`: frees region + kills task + yields
- Shell: unknown command → tries `<name>.elf` then `<name>.wasm` from mounted disk
- testMode: `make test-structured` boots `-d:testMode`, runs kernel_tests (ring 0) then user_tests.elf (ring 3)
- `launchElfBytes(name, ptr, len)` in shell.nim — public API to spawn any PIE ELF
- `virtio_pci_transport.nim::pciTransport(vendor, device)` — generic PCI vtable constructor
- VFS layer exists (`fs/vfs.nim` + fatfs/littlefs/lwext4); metadata_db B-tree host-tested green
- metadata_db kernel heap bug (seq[string] corruption) bypassed via FAT-only mount; deferred

## Build commands

```
make test              # host unit tests (all green)
make test-structured   # QEMU in-kernel test run (kernel + user ELFs)
make build             # all 3 kernel models
make iso && make qemu  # boot default ISO
```

## What each completion unblocks

| Completed | Unblocks |
|-----------|---------|
| virtio-gpu PCI migration | Display on QEMU; raylib/naylib integration; GUI apps |
| Dispatcher cap-gating (TW#32) | All I/O serialised through dispatcher; invariant enforced |
| mapAnon ring-3 verification (TW#65) | Confirm heap ABI works for apps |
| metadata_db kernel fix | Full VFS with indexed metadata; search-by-tag |
