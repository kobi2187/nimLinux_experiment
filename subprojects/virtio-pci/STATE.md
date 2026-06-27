# STATE.md — virtio-pci sub-project

Last updated: 2026-06-27 (spawn)

## Status: SPAWNED, not yet started

Created from parent NimixOS while verifying Task 1 (boot fs_server from disk).
Parent attaches `disk.img` via `-device virtio-blk-pci`; the existing MMIO-only
`virtio_blk.nim` fails at `blkFindMmio` ("BAR0 not MMIO or missing"). This
sub-project implements the modern virtio-pci transport behind the parent's frozen
`VirtioTransport` vtable.

## Frozen interface (definition of done)

`drivers/virtio/virtio_transport.nim::VirtioTransport` (in the PARENT repo):
probe / negotiate / queueSetup / notify / readConfig / irqLine.
Stub backend exists (`stubTransport`) so the parent compiles meanwhile.

## Done
- [x] V1: SURVEY — decision BUILD minimal Nim backend; reuse pci_config + pci_bar.
      Struct layouts verified against linux uapi virtio_pci.h. See DECISIONS V1.
- [x] V2: struct layouts (VirtioPciCap=16B, NotifyCap=20B, CommonCfg=56B) +
      cfg_type consts, in `drivers/virtio/virtio_pci.nim`. Host test
      `tests/test_virtio_pci.nim` green (3 assertions).

## Now
- [→] V3: walk PCI capability list (status bit4 → cap ptr @0x34), collect virtio
      caps by cfg_type. Needs a host test over a synthetic cap chain.

## Next
- V4: map BAR+offset per cap (reuse pciBarDecode) → probe() returns true in QEMU
- V5–V8: CommonCfg negotiate / queueSetup / notify / readConfig+irq
- V9: wire into virtio_blk via vtable; V10: boot done-check

## Working set
- Parent files (read-only here): `drivers/virtio/virtio_transport.nim` (the contract),
  `virtqueue.nim`, `virtio_blk.nim`, `drivers/pci/pci_bar.nim`, `pci_config.nim`
- This sub-project's code lands in the parent tree as `drivers/virtio/virtio_pci.nim`
  + `tests/test_virtio_pci.nim` (the sub-project owns those files).
- Build: `make build` (parent); host test: `nim c -r --skipParentCfg --mm:refc --path:<parent> tests/test_virtio_pci.nim`
