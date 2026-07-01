# SPDX-License-Identifier: GPL-2.0
## Virtio-sound driver (virtio spec 5.14).
##
## Exposes a single PCM output stream (stream 0) at 44100 Hz, stereo, S16LE.
## Caller fills a buffer and calls virtioSndPlay() to enqueue it for playback.
##
## Init order: PCI only (QEMU virtio-sound is always PCI).

import virtio_regs
import virtqueue
import virtio_pci
import ../pci/pci_bar
import ../pci/pci_config
import ../../core/log
import ../../core/types
import ../../mm/device_mmio

const
  VirtioSndVendor*  = 0x1AF4'u16
  VirtioSndDevice*  = 0x1059'u16
  PciRegIrqLine     = 0x3C'u8
  SndQueuePages     = 4

  # virtio-snd queue indices
  SndQCtl    = 0'u16   # control (request/response)
  SndQEvent  = 1'u16   # async events from device
  SndQTx     = 2'u16   # PCM output (stream 0)
  SndQRx     = 3'u16   # PCM input (unused here)

  # virtio-snd command types
  SndRSetParams    = 0x0100'u32
  SndRPrepare      = 0x0102'u32
  SndRStart        = 0x0103'u32
  SndRStop         = 0x0104'u32
  SndRRelease      = 0x0105'u32

  SndSOk           = 0x8000'u32
  SndSBadMsg       = 0x8001'u32

  # PCM formats / rates
  SndFmtS16Le      = 2'u8
  SndRate44100     = 5'u8

type
  SndCtlHdr* {.packed.} = object
    code*:    uint32

  SndCtlResp* {.packed.} = object
    code*:    uint32

  SndPcmSetParams* {.packed.} = object
    hdr*:         SndCtlHdr   # code = SndRSetParams
    streamId*:    uint32
    bufferBytes*: uint32
    periodBytes*: uint32
    features*:    uint32
    channels*:    uint8
    format*:      uint8
    rate*:        uint8
    padding*:     uint8

  SndPcmCmd* {.packed.} = object
    hdr*:      SndCtlHdr
    streamId*: uint32

  SndPciDev = object
    found*:      bool
    bus*, slot*, fn*: uint8
    caps*:       VirtioCaps
    common*:     ptr VirtioPciCommonCfg
    notifyBase*: uint64
    notifyMult*: uint32

  VirtioSnd* = object
    ctlQueue*:   Virtqueue
    txQueue*:    Virtqueue
    qMem*:       pointer   # DMA pages (ctl + tx queues)
    ready*:      bool
    submitted*:  uint64    # total tx buffers enqueued
    completed*:  uint64    # total tx buffers the device has consumed

var gSnd*:    VirtioSnd
var gSndDev:  SndPciDev

# ── PCI adapter procs ─────────────────────────────────────────────────────────

proc sndCfgReader(off: uint8): uint8 {.nimcall.} =
  assert gSndDev.found, "sndCfgReader: no device"
  pciConfigReadU8(gSndDev.bus, gSndDev.slot, gSndDev.fn, off)

proc sndBarBase(barIdx: uint8): uint64 {.nimcall.} =
  assert gSndDev.found, "sndBarBase: no device"
  pciBarDecode(gSndDev.bus, gSndDev.slot, gSndDev.fn, int(barIdx)).base

proc sndMapCap(loc: VirtioCapLoc): uint64 =
  let phys = capAddr(loc, sndBarBase)
  if phys == 0: return 0
  uint64(mapDeviceMmio(PhysAddr(phys), uint64(loc.length)))

proc sndNotify(queueIdx: uint16) =
  let qno = gSndDev.common.queueNotifyOff
  let at  = notifyAddr(gSndDev.notifyBase, qno, gSndDev.notifyMult)
  cast[ptr uint16](at)[] = queueIdx

# ── Control command helper ────────────────────────────────────────────────────

proc sndCtlCmd(cmd: pointer; cmdLen: uint32): uint32 =
  ## Post a control command, wait for response, return response code.
  let mem   = cast[uint64](gSnd.qMem)
  let resp  = cast[ptr SndCtlResp](mem + totalQueueBytes() * 2 + uint64(cmdLen))
  resp.code = 0xFFFFFFFF'u32
  let vq = addr gSnd.ctlQueue
  let head = vq.nextFree mod QueueSize.uint16
  let next = (vq.nextFree + 1) mod QueueSize.uint16
  vq.desc[head] = VirtqDesc(bufAddr: translatePhys(cmd), len: cmdLen,
                             flags: VirtqDescFNext, next: next)
  vq.desc[next] = VirtqDesc(bufAddr: translatePhys(resp),
                             len: uint32(sizeof(SndCtlResp)),
                             flags: VirtqDescFWrite, next: 0)
  let ai = vq.avail.idx mod QueueSize.uint16
  vq.avail.ring[ai] = head
  {.emit: "asm volatile(\"\" ::: \"memory\");".}
  vq.avail.idx = vq.avail.idx + 1
  vq.nextFree  = vq.nextFree + 2
  sndNotify(SndQCtl)
  var spins = 0
  while gSnd.ctlQueue.lastUsed == gSnd.ctlQueue.used.idx and spins < 1_000_000:
    inc spins
  discard virtqueuePop(gSnd.ctlQueue)
  resp.code

# ── Setup queue helper ────────────────────────────────────────────────────────

proc sndSetupQueue(idx: uint16; mem: pointer): Virtqueue =
  let phys = translatePhys(mem)
  gSndDev.common.queueSelect = idx
  discard commonQueueSetup(gSndDev.common, idx, phys,
                           phys + availRingOffset(), phys + usedRingOffset())
  virtqueueInitNoWire(uint32(idx), mem)

# ── Stream setup ──────────────────────────────────────────────────────────────

proc sndStreamSetup(): bool =
  var p = SndPcmSetParams(
    hdr:         SndCtlHdr(code: SndRSetParams),
    streamId:    0,
    bufferBytes: 65536,
    periodBytes: 4096,
    features:    0,
    channels:    2,
    format:      SndFmtS16Le,
    rate:        SndRate44100)
  if sndCtlCmd(addr p, uint32(sizeof(p))) != SndSOk:
    klog(llError, "virtio-snd: SET_PARAMS failed"); return false
  var prep = SndPcmCmd(hdr: SndCtlHdr(code: SndRPrepare), streamId: 0)
  if sndCtlCmd(addr prep, uint32(sizeof(prep))) != SndSOk:
    klog(llError, "virtio-snd: PREPARE failed"); return false
  var start = SndPcmCmd(hdr: SndCtlHdr(code: SndRStart), streamId: 0)
  if sndCtlCmd(addr start, uint32(sizeof(start))) != SndSOk:
    klog(llError, "virtio-snd: START failed"); return false
  true

# ── Public init ──────────────────────────────────────────────────────────────

proc virtioSndInit*(): bool =
  let f = pciVirtioFind(VirtioSndVendor, VirtioSndDevice)
  if not f.found:
    klog(llWarn, "virtio-snd: not found"); return false
  gSndDev = SndPciDev(found: true, bus: f.bus, slot: f.slot, fn: f.fn)
  let caps = walkVirtioCaps(sndCfgReader)
  if not caps.common.found:
    klog(llError, "virtio-snd: no COMMON cap"); return false
  gSndDev.caps       = caps
  gSndDev.common     = cast[ptr VirtioPciCommonCfg](sndMapCap(caps.common))
  gSndDev.notifyBase = sndMapCap(caps.notify)
  gSndDev.notifyMult = caps.notifyOffMultiplier
  if gSndDev.common == nil or gSndDev.notifyBase == 0:
    klog(llError, "virtio-snd: cap map failed"); return false
  if not commonNegotiate(gSndDev.common, 0'u64):
    klog(llError, "virtio-snd: negotiate failed"); return false
  let mem = allocDmaPages(SndQueuePages)
  if mem == nil:
    klog(llError, "virtio-snd: DMA alloc failed"); return false
  # Layout: [ctl ring | tx ring | cmd scratch | event ring] in the DMA pages
  let ctlMem = mem
  let txMem  = cast[pointer](cast[uint64](mem) + totalQueueBytes())
  gSnd.ctlQueue = sndSetupQueue(SndQCtl,   ctlMem)
  discard         sndSetupQueue(SndQEvent, txMem)  # event queue: allocate but ignore
  gSnd.txQueue  = sndSetupQueue(SndQTx,   txMem)
  gSnd.qMem     = mem
  commonSetDriverOk(gSndDev.common)
  if not sndStreamSetup():
    return false
  gSnd.ready = true
  klog(llInfo, "virtio-snd: ready (44100 Hz, stereo, S16LE)")
  true

# ── Streaming playback ─────────────────────────────────────────────────────────
# The tx queue holds up to QueueSize buffers in flight. A continuous stream
# submits chunks faster than the device drains them, so we track submitted vs
# completed and reclaim slots from the used ring. Without this, `nextFree mod
# QueueSize` wraps and overwrites descriptors the device is still playing.

proc virtioSndInFlight*(): uint64 {.inline.} =
  ## Buffers enqueued but not yet consumed by the device.
  gSnd.submitted - gSnd.completed

proc virtioSndTxDrain*(): uint64 =
  ## Reclaim completed tx buffers from the used ring. Returns how many completed
  ## this call. Cheap to call in a loop — advances `completed` as the device
  ## reports consumed buffers.
  if not gSnd.ready: return 0
  var n = 0'u64
  while true:
    let pop = virtqueuePop(gSnd.txQueue)
    if not pop.found: break
    inc gSnd.completed
    inc n
  n

proc virtioSndTxFull*(): bool {.inline.} =
  ## True when the tx ring can't accept another buffer without overwriting an
  ## in-flight one. Callers should drain + retry rather than submit.
  virtioSndInFlight() >= uint64(QueueSize)

proc virtioSndPlay*(pcmData: pointer; byteLen: uint32): bool =
  ## Enqueue one PCM buffer for playback on stream 0. Non-blocking.
  ## Returns false if the device isn't ready OR the tx ring is full (caller must
  ## drain via virtioSndTxDrain and retry). pcmData must be DMA-accessible.
  if not gSnd.ready: return false
  discard virtioSndTxDrain()          # opportunistically reclaim before checking
  if virtioSndTxFull(): return false  # backpressure: ring saturated
  let vq = addr gSnd.txQueue
  let i  = vq.nextFree mod QueueSize.uint16
  vq.desc[i] = VirtqDesc(bufAddr: translatePhys(pcmData), len: byteLen, flags: 0, next: 0)
  let ai = vq.avail.idx mod QueueSize.uint16
  vq.avail.ring[ai] = i
  {.emit: "asm volatile(\"\" ::: \"memory\");".}
  vq.avail.idx = vq.avail.idx + 1
  vq.nextFree  = vq.nextFree + 1
  inc gSnd.submitted
  sndNotify(SndQTx)
  true
