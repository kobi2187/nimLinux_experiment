# HANDOFF.md — virtio-pci sub-project

Last updated: 2026-06-27 (spawn)

Just spawned. Nothing implemented yet. Runs the same `AGENTS.md` as the parent.

**Start here:** ORIENT on these files, then execute V1 (SURVEY) from BACKLOG.md.
The frozen contract is the parent's `drivers/virtio/virtio_transport.nim`
(`VirtioTransport` vtable) — that is your definition of done. A `stubTransport`
already exists so the parent compiles; replace it with a real `virtio_pci.nim`.

**Key references in the parent tree:**
- `drivers/virtio/virtio_blk.nim` — the device driver that will call your transport
  (keep its public API `virtioBlkInit/Read/Write` unchanged).
- `drivers/virtio/virtqueue.nim` — transport-agnostic ring mechanics (reuse).
- `drivers/pci/pci_bar.nim`, `pci_config.nim` — BAR decode + PCI config reads.
- virtio spec §4.1 (PCI transport) — the capability layout you implement.

**Done-check for the whole sub-project:** `make test-structured` (with the
virtio-blk disk) shows `fs_server: starting` before the shell prompt.
