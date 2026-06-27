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

## V1 SURVEY — Build a minimal Nim virtio-pci backend (2026-06-27)

**Examined:**
- virtio spec §4.1.4 (virtio-pci capability layout): vendor cap id 0x09, each cap has
  `cfg_type` (1=COMMON, 2=NOTIFY, 3=ISR, 4=DEVICE), `bar`, `offset`, `length`;
  NOTIFY cap adds `notify_off_multiplier`. CommonCfg is a fixed MMIO struct
  (device/driver feature select+window, queue select/size/enable/notify_off, the
  three ring phys addresses, device_status, etc.).
- Existing NimixOS PCI helpers: `drivers/pci/pci_config.nim` (u8/u16/u32 read/write)
  and `drivers/pci/pci_bar.nim` (`pciBarDecode` — already handles 64-bit MMIO BARs,
  returns base+size). These cover everything except the capability-list walk.
- Alternatives: porting a C virtio-pci driver / libvirtio — both assume an OS/libc and
  a far larger surface; impedance mismatch with `--os:any`.

**Decision: BUILD** a small Nim backend (~150 LOC) implementing `VirtioTransport`:
  - cap-walk: status reg bit 4 → cap ptr @0x34 → traverse, collect virtio caps by cfg_type
  - map each cap's (bar, offset) via `pciBarDecode` + offset
  - CommonCfg-based negotiate / queueSetup; notify via NOTIFY bar+offset; INTx irq line
**Rejected build-from-scratch of PCI primitives** — reuse pci_config + pci_bar.

**Plan:** V2 struct layouts (host tests) → V3 cap-walk → V4 BAR map → V5–V8 vtable ops
→ V9 wire into virtio_blk → V10 boot done-check. virtio-gpu migrates onto the same
vtable afterward (it has the identical MMIO-only blocker).
