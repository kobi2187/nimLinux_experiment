# VISION.md — virtio-pci transport (sub-project)

## What it is

A NimixOS virtio **modern (virtio-1.0) PCI transport** backend. It implements the
parent's frozen `VirtioTransport` vtable so that block (and later net) drivers work
against QEMU's `virtio-blk-pci` / `virtio-net-pci` devices, which expose their
configuration through PCI capabilities rather than a legacy MMIO register window.

## Definition of done (the API contract)

Implements `drivers/virtio/virtio_transport.nim::VirtioTransport`:
`probe / negotiate / queueSetup / notify / readConfig / irqLine`.

Done when:
1. `virtioBlkInit()` (parent, unchanged API) succeeds against QEMU
   `-device virtio-blk-pci` — no "BAR0 not MMIO" error.
2. `virtioBlkRead`/`virtioBlkWrite` round-trip a 512-byte sector correctly.
3. `fsMount()` succeeds at boot; `fs_server: starting` appears on serial before the
   shell prompt (this closes parent Task 1 / Milestone 1 / open question #1).
4. Host tests cover the PCI capability walk and the virtio-pci struct layouts
   (CommonCfg, NotifyCap, etc.) without QEMU.

## What it is not

- Not a rewrite of virtqueue mechanics or the blk request format — those stay in the
  parent's transport-agnostic `virtqueue.nim` / `virtio_blk.nim`.
- Not legacy MMIO (that's `virtio_mmio.nim`, a sibling backend).
- Not MSI-X (start with legacy INTx; MSI-X is a later option).

## Non-negotiable constraints (inherited)

- `--os:any` kernel context: no `string`, no stdlib alloc; `cstring`/arrays/manual bufs.
- Procs 5–8 lines; assert invariants at entry; small composable helpers.
- The only thing crossing the parent boundary is the `VirtioTransport` struct. Changing
  it is cross-cutting in BOTH projects → dialogue + log in both DECISIONS.md.

## First task

SURVEY: find a mature, minimal virtio-1.0 PCI reference to adapt (virtio spec §4.1
capability layout; small hobby-OS / reference implementations). Decide adopt/adapt/build.

## Open questions

| # | Question | Resolving signal |
|---|----------|-----------------|
| 1 | Legacy INTx vs MSI-X for completion interrupts? | When sync polling works and we add async completion |
| 2 | Does `queueSetup` need the full split-ring phys triple (desc/avail/used) or is one base + offsets enough for QEMU? | When CommonCfg queue registration is implemented |
