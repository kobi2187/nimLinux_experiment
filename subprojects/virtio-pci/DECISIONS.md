# DECISIONS.md — virtio-pci sub-project (append-only)

## Spawn (2026-06-27)

Spawned from parent NimixOS. The block driver was MMIO-only; QEMU attaches
`virtio-blk-pci`. Rather than tangle two transports in one file, the parent
introduced a `VirtioTransport` vtable seam and spawned this sub-project to implement
the modern virtio-1.0 PCI backend. Full rationale + the frozen vtable: parent
`DECISIONS.md §"Virtio transport split — MMIO vs PCI" (2026-06-27)`.

**Boundary:** the ONLY thing crossing into the parent is the `VirtioTransport`
struct. Any change to it is logged here AND in the parent's DECISIONS.md.

**Definition of done:** see VISION.md — `virtioBlkInit()` works against virtio-blk-pci,
sector round-trips, `fs_server: starting` appears at boot.
