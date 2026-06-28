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
- [x] V9: transport wired into `virtio_blk.nim` via the VirtioTransport vtable.
      New `drivers/virtio/virtio_pci_transport.nim` builds the vtable over the real
      `pciConfigReadU8` (CfgReader) + `pciBarDecode(...).base` (BarBaseFn) adapters,
      keyed on a module-global found device (nimcall procs can't capture).
      `virtioBlkInit` = `virtioBlkInitPci() or virtioBlkInitMmio()`; PCI path probes
      (walkVirtioCaps+capAddr), negotiates, lays the ring via `virtqueueInitNoWire`,
      registers it with `commonQueueSetup`, kicks via `transport.notify`.
      Public API unchanged. `make build` (all 3 models) + `make test` green.
      BLOCKER for V10 only: uncached device mapping — see "Note on volatility".

## Now (V10 — QEMU boot proof: PARTIAL, one bug left)
- [→] V10: LIVE QEMU result (2026-06-28, direct run, disk via virtio-blk-pci).
      REPRODUCES IDENTICALLY in BOTH the release OS boot (`nimixos.iso`, -d:release
      -d:danger → runShell) AND the testMode kernel — so NOT a testMode/harness
      artifact; it is a real bug in the production virtio-blk request path (rules out
      cli/sti testMode load + opt-level as causes):
  - **Probe/config PATH WORKS:** serial shows `virtio-blk(pci): ready, sectors=65536`.
    Proves end-to-end: device-mmio uncached BAR map → cap-walk (COMMON/NOTIFY/ISR/
    DEVICE) → `commonNegotiate` FEATURES_OK → `deviceConfigRead32` reads real capacity
    (65536 sectors = 32 MB disk.img). The hard V1–V9 work is confirmed in hardware.
  - **DMA PATH FAILS:** first real `blkRead` during `vfsMount` → `[ERROR] virtio-blk:
    request timed out` (used-ring idx never advances) → `fs: mount failed, err=1` →
    `boot: disk not available — servers will not load`. So `fs_server: starting` does
    NOT appear; the V10 done-check is NOT yet met.
  - **Leading hypothesis (virt/phys DMA mismatch):** `virtioBlkInitPci` passes
    `cast[uint64](mem)` (= `regionBase`, a *virtual* addr) to `t.queueSetup` and as the
    desc bufAddr. Config reads are CPU→device MMIO (work). DMA is device→memory and
    needs the *physical* ring/buffer address. If the region is not identity-mapped
    (virt==phys), the device DMAs to the wrong place and the used ring never updates →
    timeout. Verify region phys==virt; if not, translate via virtual_manager before
    handing addresses to the device. Secondary suspects (lower prob): notify address
    (`queueNotifyOff`/`notifyOffMultiplier`), or avail-ring barrier/ordering.
- Then (after V10 green): migrate virtio-gpu onto the same vtable → lights up display.

## NOTE: pre-existing untracked work discovered this session
The tree already contained (uncommitted, NOT from this session): a VFS layer
(`fs/vfs.nim` + fatfs/littlefs/lwext4 drivers — 9 kernel_tests PASS) and a
metadata_db B-tree (`fs/metadata_db.nim` — **8 kernel_tests FAIL**). kernel_tests is
now 43 tests (was 24). UNRELATED to virtio-pci. Parent STATE/ARCHITECTURE do not yet
reflect this VFS/db layer — reconcile later.

### metadata_db bug — DEFERRED (parked 2026-06-28), diagnosis complete
Symptom (in-kernel only): insert blanks the previously-inserted key (`keys=["","artist:
Daft Punk:2"]`), queryPrefix returns 0, deserialize yields space-corrupted keys
(`"                :1"`). NOT an algorithm bug: `tests/test_vfs_btree.nim` PASSES on host
under --mm:refc AND --mm:arc AND --mm:arc+-d:danger. Reproduces ONLY in the real
`--os:any` kernel runtime → root cause is the standalone/bump heap's handling of
`seq[string]` / dynamic strings, not the B+tree logic.
**Resolving direction (when picked up):** refactor metadata_db off dynamic
`seq[string]` onto fixed-size `array[N,char]` keys (aligns with the project's
stdlib-caution rule for kernel code); that likely fixes the allocator bug AND makes it
host-testable. TDD then applies cleanly. Decision: deferred behind V10 (the real
Milestone-1 blocker); db is not on the boot-from-disk path.

## Note on volatility — CROSS-CUTTING, UNRESOLVED (escalated to parent)
CommonCfg ops write through `ptr VirtioPciCommonCfg`. On the kernel path the region
must be mapped uncached so ordinary stores are real MMIO writes.

V9 finding: there is NO existing uncached-map path to reuse. The legacy MMIO path
(`blkFindMmio`) just casts `bar.base` to a pointer and dereferences it — it relies on
the boot stub's identity map, which covers only the low 64 MB via 2 MB huge pages
with NO PCD bit (`arch/x86_64/boot_asm.S`). `mm/virtual_manager.nim` HAS the machinery
(`pfCacheDisable` → PTE_PCD, `mapRegion`) but it is never called at runtime to map
device memory. QEMU's virtio-pci BARs sit high (~0xFExxxxxx) and are neither mapped
nor uncached. Per task constraints I did NOT modify `virtual_manager.nim`; this is a
parent-boundary decision. V10 will need a one-call `mapRegion(kernelSpace, base, base,
len, {pfWritable, pfCacheDisable})` for each cap region at probe time (applies equally
to the legacy MMIO path, which is why MMIO currently fails for high BARs).

## Working set
- Parent files (read-only here): `drivers/virtio/virtio_transport.nim` (the contract),
  `virtqueue.nim`, `virtio_blk.nim`, `drivers/pci/pci_bar.nim`, `pci_config.nim`
- This sub-project's code lands in the parent tree as `drivers/virtio/virtio_pci.nim`
  + `tests/test_virtio_pci.nim` (the sub-project owns those files).
- Build: `make build` (parent); host test: `nim c -r --skipParentCfg --mm:refc --path:<parent> tests/test_virtio_pci.nim`
