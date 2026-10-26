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
import std/volatile
import ../pci/pci_bar
import ../pci/pci_config
import ../../core/log
import ../../core/types
import ../../mm/device_mmio

const
  VirtioSndVendor*  = 0x1AF4'u16
  VirtioSndDevice*  = 0x1059'u16
  PciRegIrqLine     = 0x3C'u8

  # virtio-snd queue indices
  SndQCtl    = 0'u16   # control (request/response)
  SndQEvent  = 1'u16   # async events from device
  SndQTx     = 2'u16   # PCM output (stream 0)
  SndQRx     = 3'u16   # PCM input (unused here)

  # virtio-snd request codes (spec 5.14.6). 0x0100 is PCM_INFO — the driver
  # used to send SET_PARAMS as 0x0100, which QEMU parsed as an info query.
  SndRPcmInfo      = 0x0100'u32
  SndRSetParams    = 0x0101'u32
  SndRPrepare      = 0x0102'u32
  SndRRelease      = 0x0103'u32
  SndRStart        = 0x0104'u32
  SndRStop         = 0x0105'u32
  SndPeriodBytes*  = 4096'u32

  SndSOk           = 0x8000'u32
  SndSBadMsg       = 0x8001'u32

  # PCM format / rate enums (spec 5.14.6.6.2): S16 = 5, 44100 Hz = 6
  SndFmtS16Le      = 5'u8
  SndRate44100     = 6'u8

  # One PCM transfer = 3 descriptors: xfer header (stream id, device-readable),
  # PCM frames, status (device-writable) — spec 5.14.6.8.
  TxDescsPerReq    = 3
  MaxTxReqs*       = QueueSize div TxDescsPerReq

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

  SndTxSlot {.packed.} = object
    streamId: uint32   ## virtio_snd_pcm_xfer       (device-readable)
    status:   uint32   ## virtio_snd_pcm_status     (device-writable)
    latency:  uint32

  SndDma = object      ## DMA layout: rings, control scratch, tx slots
    ctlRing:   array[8192, byte]
    eventRing: array[8192, byte]
    txRing:    array[8192, byte]
    ctlCmd:    array[64, byte]
    ctlResp:   SndCtlResp
    txSlots:   array[MaxTxReqs, SndTxSlot]

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
    dma:         ptr SndDma   # rings + control scratch + tx slots
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
  commonKick(gSndDev.common, gSndDev.notifyBase, gSndDev.notifyMult, queueIdx)

# ── Control command helper ────────────────────────────────────────────────────

proc sndCtlCmd(cmd: pointer; cmdLen: uint32): uint32 =
  ## Post a control command (copied into DMA scratch), wait for the device's
  ## response, return the response code (0xFFFFFFFF on timeout).
  assert cmdLen <= uint32(sizeof(gSnd.dma.ctlCmd)), "sndCtlCmd: command too large"
  copyMem(addr gSnd.dma.ctlCmd[0], cmd, int(cmdLen))
  gSnd.dma.ctlResp.code = 0xFFFFFFFF'u32
  let vq = addr gSnd.ctlQueue
  let head = vq.nextFree mod QueueSize.uint16
  let next = (vq.nextFree + 1) mod QueueSize.uint16
  vq.desc[head] = VirtqDesc(bufAddr: translatePhys(addr gSnd.dma.ctlCmd[0]), len: cmdLen,
                             flags: VirtqDescFNext, next: next)
  vq.desc[next] = VirtqDesc(bufAddr: translatePhys(addr gSnd.dma.ctlResp),
                             len: uint32(sizeof(SndCtlResp)),
                             flags: VirtqDescFWrite, next: 0)
  let ai = vq.avail.idx mod QueueSize.uint16
  vq.avail.ring[ai] = head
  {.emit: "asm volatile(\"\" ::: \"memory\");".}
  vq.avail.idx = vq.avail.idx + 1
  vq.nextFree  = vq.nextFree + 2
  sndNotify(SndQCtl)
  var spins = 0
  # usedIdx is an acquire load: a plain read could be hoisted out of the loop.
  while vq.lastUsed == usedIdx(vq[]) and spins < 10_000_000:
    inc spins
  if vq.lastUsed == usedIdx(vq[]):
    klog(llError, "virtio-snd: control request timed out")
    return 0xFFFFFFFF'u32
  discard virtqueuePop(vq[])
  {.emit: "asm volatile(\"\" ::: \"memory\");".}
  gSnd.dma.ctlResp.code

# ── Setup queue helper ────────────────────────────────────────────────────────

proc sndSetupQueue(idx: uint16; mem: pointer; vq: var Virtqueue): bool =
  if not pciQueueAttach(gSndDev.common, idx, translatePhys(mem)):
    klogInt(llError, "virtio-snd: queue setup failed, queue=", int64(idx))
    return false
  vq = virtqueueInitNoWire(uint32(idx), mem)
  true

# ── Stream setup ──────────────────────────────────────────────────────────────

proc sndStreamCmd(code: uint32; failMsg: cstring): bool =
  ## One stream-0 state change (PREPARE/START/STOP/RELEASE); logs on failure.
  var c = SndPcmCmd(hdr: SndCtlHdr(code: code), streamId: 0)
  result = sndCtlCmd(addr c, uint32(sizeof(c))) == SndSOk
  if not result: klog(llError, failMsg)

proc sndStreamSetup(): bool =
  var p = SndPcmSetParams(
    hdr:         SndCtlHdr(code: SndRSetParams),
    streamId:    0,
    bufferBytes: 65536,
    periodBytes: SndPeriodBytes,
    features:    0,
    channels:    2,
    format:      SndFmtS16Le,
    rate:        SndRate44100)
  if sndCtlCmd(addr p, uint32(sizeof(p))) != SndSOk:
    klog(llError, "virtio-snd: SET_PARAMS failed"); return false
  sndStreamCmd(SndRPrepare, "virtio-snd: PREPARE failed") and
    sndStreamCmd(SndRStart, "virtio-snd: START failed")

# ── Public init ──────────────────────────────────────────────────────────────

proc virtioSndInit*(): bool =
  let f = pciVirtioFind(VirtioSndVendor, VirtioSndDevice)
  if not f.found:
    klog(llWarn, "virtio-snd: not found"); return false
  gSndDev = SndPciDev(found: true, bus: f.bus, slot: f.slot, fn: f.fn)
  pciDisableIntx(f.bus, f.slot, f.fn)      # polled driver
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
  assert totalQueueBytes() <= 8192'u64, "virtio-snd: ring slot too small"
  let pages = (sizeof(SndDma) + 4095) div 4096
  let mem = allocDmaPages(pages)
  if mem == nil:
    klog(llError, "virtio-snd: DMA alloc failed"); return false
  zeroMem(mem, sizeof(SndDma))
  gSnd.dma = cast[ptr SndDma](mem)
  # Each queue gets its own ring (event and tx used to share one).
  var eventQueue: Virtqueue           # no event buffers posted (unused)
  if not (sndSetupQueue(SndQCtl,   addr gSnd.dma.ctlRing[0],   gSnd.ctlQueue) and
          sndSetupQueue(SndQEvent, addr gSnd.dma.eventRing[0], eventQueue) and
          sndSetupQueue(SndQTx,    addr gSnd.dma.txRing[0],    gSnd.txQueue)):
    return false
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

const TxStatusPending = 0xFFFFFFFF'u32   ## written before submit; device overwrites

proc txSlotDone(r: int): bool {.inline.} =
  volatileLoad(addr gSnd.dma.txSlots[r].status) != TxStatusPending

proc virtioSndTxDrain*(): uint64 =
  ## Reclaim completed tx requests. Returns how many completed this call.
  ##
  ## Completion = the device wrote the request's status. QEMU 8.2 fills tx
  ## used-ring entries but never publishes used.idx (trace: virtqueue_fill
  ## without virtqueue_flush), so used.idx alone would stall playback forever.
  ## One stream plays FIFO, so requests complete in submission order.
  if not gSnd.ready: return 0
  while virtqueuePop(gSnd.txQueue).found: discard   # keep lastUsed in step
  var n = 0'u64
  while gSnd.completed < gSnd.submitted and
        txSlotDone(int(gSnd.completed mod uint64(MaxTxReqs))):
    inc gSnd.completed
    inc n
  n

proc virtioSndTxFull*(): bool {.inline.} =
  ## True when every tx request slot (3 descriptors each) is in flight.
  ## Callers should drain + retry rather than submit.
  virtioSndInFlight() >= uint64(MaxTxReqs)

proc virtioSndPlay*(pcmData: pointer; byteLen: uint32): bool =
  ## Enqueue one PCM buffer for playback on stream 0. Non-blocking.
  ## The device plays whole periods (SndPeriodBytes): a trailing partial period
  ## is held until more data arrives, so pad the end of a sound with silence.
  ## Returns false if the device isn't ready OR the tx ring is full (caller must
  ## drain via virtioSndTxDrain and retry). pcmData must be DMA-accessible.
  if not gSnd.ready: return false
  discard virtioSndTxDrain()          # opportunistically reclaim before checking
  if virtioSndTxFull(): return false  # backpressure: ring saturated
  let vq = addr gSnd.txQueue
  # Request r owns descriptors 3r..3r+2 and tx slot r — never shared while
  # in flight (TxFull caps in-flight at MaxTxReqs).
  let r    = int(gSnd.submitted mod uint64(MaxTxReqs))
  let d0   = uint16(r * TxDescsPerReq)
  let slot = addr gSnd.dma.txSlots[r]
  slot.streamId = 0
  slot.status   = TxStatusPending
  vq.desc[d0]     = VirtqDesc(bufAddr: translatePhys(addr slot.streamId), len: 4,
                              flags: VirtqDescFNext, next: d0 + 1)
  vq.desc[d0 + 1] = VirtqDesc(bufAddr: translatePhys(pcmData), len: byteLen,
                              flags: VirtqDescFNext, next: d0 + 2)
  vq.desc[d0 + 2] = VirtqDesc(bufAddr: translatePhys(addr slot.status), len: 8,
                              flags: VirtqDescFWrite, next: 0)
  let ai = vq.avail.idx mod QueueSize.uint16
  vq.avail.ring[ai] = d0
  {.emit: "asm volatile(\"\" ::: \"memory\");".}
  vq.avail.idx = vq.avail.idx + 1
  inc gSnd.submitted
  sndNotify(SndQTx)
  true

proc virtioSndFinish*(): bool =
  ## End of a sound: hand back the request the device still holds (QEMU keeps
  ## the last one until the stream is flushed, which RELEASE does), then
  ## re-arm the stream for the next sound. STOP→RELEASE→PREPARE→START is the
  ## spec's (5.14.6.6) stream state cycle.
  if not gSnd.ready: return false
  result = sndStreamCmd(SndRStop, "virtio-snd: STOP failed") and
           sndStreamCmd(SndRRelease, "virtio-snd: RELEASE failed") and
           sndStreamCmd(SndRPrepare, "virtio-snd: PREPARE failed") and
           sndStreamCmd(SndRStart, "virtio-snd: START failed")
  discard virtioSndTxDrain()
