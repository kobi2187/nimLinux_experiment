# SPDX-License-Identifier: GPL-2.0
## VirtioTransport — frozen seam between virtio device drivers (blk, net) and the
## underlying transport (legacy MMIO vs modern PCI).
##
## A device driver (virtio_blk, virtio_net) owns its virtqueue + request format and
## calls through a VirtioTransport vtable for everything transport-specific:
## discovery, the status/feature handshake, queue ring registration, queue notify
## (kick), device-config reads, and the IRQ line.
##
## Two backends implement this:
##   - virtio_mmio.nim  — legacy/MMIO transport (BAR0 + VirtioReg* register window)
##   - virtio_pci.nim   — modern virtio-1.0 PCI transport (capability walk)  [SPAWNED]
##
## API freeze: see DECISIONS.md §"Virtio transport split" (2026-06-27). Any change
## to this struct is cross-cutting — log it in DECISIONS.md AND the virtio-pci
## sub-project's DECISIONS.md, and update both drift logs.

type
  VirtioTransport* = object
    ## Vtable filled in by a transport backend. All procs are {.nimcall.}.
    probe*:      proc(): bool {.nimcall.}
      ## Discover the device, map its register window / BARs. False if absent.
    negotiate*:  proc(features: uint64): bool {.nimcall.}
      ## Status handshake (ACK→DRIVER→FEATURES_OK). False if FEATURES_OK rejected.
    queueSetup*: proc(idx: uint16; ringPhys: uint64): bool {.nimcall.}
      ## Register a virtqueue's ring physical address with the device.
    notify*:     proc(idx: uint16) {.nimcall.}
      ## Kick queue `idx` (tell the device new buffers are available).
    readConfig*: proc(off: uint32): uint32 {.nimcall.}
      ## Read 32 bits from the device-specific config space at byte offset `off`.
    irqLine*:    proc(): uint8 {.nimcall.}
      ## The legacy INTx IRQ line for this device.

proc isWired*(t: VirtioTransport): bool {.inline.} =
  ## A transport is usable once at least probe + negotiate + notify are set.
  t.probe != nil and t.negotiate != nil and t.notify != nil

# ── Stub backend ───────────────────────────────────────────────────────────────
# Placeholder so callers compile before virtio_mmio/virtio_pci are wired.
# Returns a transport whose probe() fails — drivers treat the device as absent.

proc stubTransport*(): VirtioTransport =
  VirtioTransport(
    probe:      proc(): bool {.nimcall.} = false,
    negotiate:  proc(features: uint64): bool {.nimcall.} = false,
    queueSetup: proc(idx: uint16; ringPhys: uint64): bool {.nimcall.} = false,
    notify:     proc(idx: uint16) {.nimcall.} = discard,
    readConfig: proc(off: uint32): uint32 {.nimcall.} = 0'u32,
    irqLine:    proc(): uint8 {.nimcall.} = 0'u8,
  )
