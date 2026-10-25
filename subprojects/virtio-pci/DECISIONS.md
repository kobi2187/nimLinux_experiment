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

## V9 — Transport wiring + uncached-mapping escalation (2026-06-27)

**Wiring:** new `drivers/virtio/virtio_pci_transport.nim` builds the frozen
`VirtioTransport` vtable. Adapters are `{.nimcall.}` (can't capture), so the found
device (bus/slot/fn) + resolved cap addresses live in a module-global `gDev`
(same pattern as `gVirtioBlk`). `cfgReader` wraps `pciConfigReadU8`; `barBase` wraps
`pciBarDecode(...).base`. `virtioBlkInit` is now `virtioBlkInitPci() or
virtioBlkInitMmio()`. Split `virtqueueInit` into `placeRings` + `virtqueueInitNoWire`
so the PCI path lays the ring without legacy MMIO queue-register writes, then registers
it through `commonQueueSetup`; exported `availRingOffset`/`usedRingOffset` for the split.

**Uncached mapping — ESCALATED, not done.** No existing uncached-map path exists to
reuse: the legacy MMIO transport relies on the boot stub's 64 MB identity map (no PCD),
and `mapRegion`/`pfCacheDisable` in `virtual_manager.nim` are never invoked at runtime
for device memory. Did NOT touch `virtual_manager.nim` per constraint. V10 must add a
`mapRegion(..., {pfWritable, pfCacheDisable})` per cap region at probe time — a parent
boundary call that also fixes the legacy MMIO high-BAR failure.

## 2026-06-28 — device-mmio seam built; V10 result; build observability

**`mm/device_mmio.nim` seam (parent):** general `mapDeviceMmio(phys,len): VirtAddr`
over the existing `kernelMapRegion(..., {pfWritable,pfCacheDisable})`; idempotent;
boot registers the live VMM via `registerDeviceMapper` in `initVirtHeap`. Chosen over
per-cap `mapRegion` calls (user decision) so all drivers share one MM-facing primitive.
Compiles into all 3 models.

**V10 LIVE result (release `nimixos.iso` AND testMode, disk via virtio-blk-pci):**
probe/config WORKS — `virtio-blk(pci): ready, sectors=65536` (cap-walk + negotiate +
deviceConfigRead all confirmed in hardware). But first real `blkRead` → `request timed
out` (used-ring idx never advances) → mount fails → servers don't load. Ruled out
virt/phys DMA (regions identity-mapped at 4MB). Leading suspects: notify/kick address
or a missing barrier between avail.idx write (cached ring) and notify. Dispatched
`v10-debug` agent (TDD: failing host test first) to fix.

**Build observability (user-driven):** `-d:danger` was hiding real defects. Makefile
now defaults checks ON (`DANGER` opt-in; `release` target restores it). Added
`kernel/init/panicoverride.nim` (serial-routed defect handler). VALIDATED: the checked
**monolithic** kernel boots all the way to the `nimixos>` shell — checks-on works for
the normal OS, Makefile change is sound (no revert).

**CORRECTION:** earlier "checked faults pre-serial" was WRONG — it was observed only on
the checked **testMode** build (0-byte log). The fault is SPECIFIC TO `-d:testMode`
(the very-early `kernelTestMain()` under cli(), or the staticRead user_tests embed),
NOT checks-on in general. This is checks-on doing its JOB: catching a real testMode
defect the danger build silently survived. Tracked as its own (smaller, scoped to
testMode early path) task — bisect with serial checkpoints/asserts when picked up.
Does NOT block normal OS debugging: `make build` + `make iso` boot to shell with
checks live.

## 2026-10-25 — V10 root cause: non-volatile CommonCfg stores (parent ADR V10b)
Additive API in `virtio_pci.nim`: `cfgGet`/`cfgSet` (volatile CommonCfg access),
`notifyWrite`, `commonKick` (select-then-read notify_off), `isrRead`. Existing
procs keep their signatures. Root cause and evidence: parent DECISIONS.md §V10b.
