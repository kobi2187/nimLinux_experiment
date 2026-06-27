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

- [x] V3: cap-walk (`walkVirtioCaps`) over an injected CfgReader — finds all four
      virtio caps, records bar+offset, empty when status bit4 clear. 3 host tests.
- [x] V4: `capAddr` = barBase(injected) + offset. 2 host tests.
- [x] V5: `commonNegotiate` — status ACK→DRIVER→FEATURES_OK on a CommonCfg ptr.
- [x] V6: `commonQueueSetup` — writes split-ring desc/avail/used lo/hi, enables queue.
- [x] V7: `notifyAddr` = base + queueNotifyOff * multiplier.
- [x] V8: `deviceConfigRead32`. All internals host-tested: `tests/test_virtio_pci.nim`
      = 11 assertions green, wired into `make test`. Module type-checks under --os:any.

## Now (QEMU-dependent — separate pass)
- [→] V9: wire transport into `virtio_blk.nim` via the VirtioTransport vtable;
      `virtioBlkInit` tries PCI (probe via pciVirtioFind + walkVirtioCaps + capAddr)
      then falls back to MMIO. Needs the real `pciConfigReadU8`/`pciBarDecode` adapters.

## Next
- V10: boot done-check in QEMU — fsMount succeeds, `fs_server: starting` before prompt.
- Then: migrate virtio-gpu onto the same vtable → lights up the display.

## Note on volatility
CommonCfg ops write through `ptr VirtioPciCommonCfg`. On the kernel path the region
must be mapped uncached so ordinary stores are real MMIO writes (verify at V9 wiring).

## Working set
- Parent files (read-only here): `drivers/virtio/virtio_transport.nim` (the contract),
  `virtqueue.nim`, `virtio_blk.nim`, `drivers/pci/pci_bar.nim`, `pci_config.nim`
- This sub-project's code lands in the parent tree as `drivers/virtio/virtio_pci.nim`
  + `tests/test_virtio_pci.nim` (the sub-project owns those files).
- Build: `make build` (parent); host test: `nim c -r --skipParentCfg --mm:refc --path:<parent> tests/test_virtio_pci.nim`
