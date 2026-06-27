# BACKLOG.md — virtio-pci sub-project

Tags: CLEAR | FUZZY | OPEN | PARENT | SPAWN

## Layer 0 — Survey + scaffolding

| # | Tag | Description | Done-check |
|---|-----|-------------|-----------|
| V1 | CLEAR | SURVEY: virtio-1.0 PCI cap layout (spec §4.1); find reference to adopt/adapt | DECISIONS.md records examined options + choice |
| V2 | CLEAR | Define virtio-pci struct layouts: VirtioPciCap, CommonCfg, NotifyCap + host struct-size tests | `tests/test_virtio_pci.nim` asserts packed offsets/sizes |

## Layer 1 — Capability walk + mapping

| # | Tag | Description | Done-check |
|---|-----|-------------|-----------|
| V3 | CLEAR | Walk PCI capability list (status bit 4 → cap ptr 0x34), collect virtio caps by cfg_type | host test over a synthetic cap chain finds CommonCfg/Notify/ISR/Device |
| V4 | CLEAR | Map BAR + offset for each cap region (reuse parent pci_bar) | probe() returns true against virtio-blk-pci in QEMU |

## Layer 2 — Transport vtable impl

| # | Tag | Description | Done-check |
|---|-----|-------------|-----------|
| V5 | CLEAR | `negotiate(features)`: device_status handshake via CommonCfg (ACK→DRIVER→FEATURES_OK) | FEATURES_OK reads back set |
| V6 | CLEAR | `queueSetup(idx, ringPhys)`: select queue, write desc/avail/used addrs, queue_enable | queue registered; no device error |
| V7 | CLEAR | `notify(idx)`: write to notify BAR (cap_off + queue_notify_off * notify_off_multiplier) | kick reaches device |
| V8 | CLEAR | `readConfig(off)` + `irqLine()`: device-cfg region read; INTx line from PCI cfg | blkReadCap returns correct sector count |

## Layer 3 — Integration (parent boundary)

| # | Tag | Description | Done-check |
|---|-----|-------------|-----------|
| V9 | CLEAR | Wire transport into `virtio_blk.nim` via vtable; `virtioBlkInit` tries PCI then MMIO | blkRead/Write round-trip a sector in QEMU |
| V10 | CLEAR | Parent done-check: fsMount succeeds, `fs_server: starting` before prompt | `make test-structured` (virtio-blk) shows fs_server boot |
