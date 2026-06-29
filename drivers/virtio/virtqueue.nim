# SPDX-License-Identifier: GPL-2.0
## Virtqueue — split-ring implementation for virtio devices.
##
## Each queue has three rings placed in contiguous DMA memory:
##   1. Descriptor table  (driver writes, device reads)
##   2. Available ring    (driver→device: descriptor indices to process)
##   3. Used ring         (device→driver: completed descriptor indices)

import virtio_regs
import ../../arch/common/atomics
import ../../mm/device_mmio

const
  QueueSize* = 256    # must be a power of two ≤ QueueNumMax

  VirtqDescFWrite*  = 0x0002'u16   # device-writable buffer
  VirtqDescFNext*   = 0x0001'u16   # buffer has a next chain entry

type
  VirtqDesc* {.packed.} = object
    bufAddr*:  uint64
    len*:   uint32
    flags*: uint16
    next*:  uint16

  VirtqAvail* {.packed.} = object
    flags*: uint16
    idx*:   uint16
    ring*:  array[QueueSize, uint16]

  VirtqUsedElem* {.packed.} = object
    id*:  uint32
    len*: uint32

  VirtqUsed* {.packed.} = object
    flags*: uint16
    idx*:   uint16
    ring*:  array[QueueSize, VirtqUsedElem]

  Virtqueue* = object
    desc*:     ptr array[QueueSize, VirtqDesc]
    avail*:    ptr VirtqAvail
    used*:     ptr VirtqUsed
    lastUsed*: uint16
    nextFree*: uint16
    mmioBase*: uint64
    queueIdx*: uint32

# ── Layout helpers ──────────────────────────────────────────────────────────

proc alignUp(p: uint64; align: uint64): uint64 {.inline.} =
  (p + align - 1) and not (align - 1)

proc descTableSize(): uint64 {.inline.} =
  uint64(QueueSize) * uint64(sizeof(VirtqDesc))

proc availRingOffset*(): uint64 {.inline.} =
  alignUp(descTableSize(), 2)

proc usedRingOffset*(): uint64 {.inline.} =
  alignUp(availRingOffset() + uint64(sizeof(VirtqAvail)), 4)

proc totalQueueBytes*(): uint64 =
  usedRingOffset() + uint64(sizeof(VirtqUsed))

# ── MMIO wiring ─────────────────────────────────────────────────────────────

proc writeQueueAddrs(vq: Virtqueue) =
  let descAddr   = translatePhys(vq.desc)
  let availAddr  = translatePhys(vq.avail)
  let usedAddr   = translatePhys(vq.used)
  let base       = vq.mmioBase
  let qi         = vq.queueIdx
  mmioWrite32(base, VirtioRegQueueSel, qi)
  mmioWrite32(base, VirtioRegQueueNum, QueueSize.uint32)
  mmioWrite32(base, VirtioRegQueueDescLo,   uint32(descAddr))
  mmioWrite32(base, VirtioRegQueueDescHi,   uint32(descAddr shr 32))
  mmioWrite32(base, VirtioRegQueueDriverLo, uint32(availAddr))
  mmioWrite32(base, VirtioRegQueueDriverHi, uint32(availAddr shr 32))
  mmioWrite32(base, VirtioRegQueueDeviceLo, uint32(usedAddr))
  mmioWrite32(base, VirtioRegQueueDeviceHi, uint32(usedAddr shr 32))
  mmioWrite32(base, VirtioRegQueueReady, 1'u32)

# ── Public API ───────────────────────────────────────────────────────────────

proc placeRings(mem: pointer; mmioBase: uint64; queueIdx: uint32): Virtqueue =
  ## Lay out and zero the three rings in `mem`; no device wiring.
  let base = cast[uint64](mem)
  result.desc     = cast[ptr array[QueueSize, VirtqDesc]](base)
  result.avail    = cast[ptr VirtqAvail](base + availRingOffset())
  result.used     = cast[ptr VirtqUsed](base + usedRingOffset())
  result.mmioBase = mmioBase
  result.queueIdx = queueIdx
  var p = cast[ptr UncheckedArray[uint8]](mem)
  for i in 0..<int(totalQueueBytes()): p[i] = 0

proc virtqueueInit*(mmioBase: uint64; queueIdx: uint32; mem: pointer): Virtqueue =
  ## Place descriptor/avail/used rings in `mem` and wire them via MMIO.
  result = placeRings(mem, mmioBase, queueIdx)
  writeQueueAddrs(result)

proc virtqueueInitNoWire*(queueIdx: uint32; mem: pointer): Virtqueue =
  ## Place the rings but skip MMIO wiring — the caller registers the ring phys
  ## address through a transport (e.g. virtio-pci CommonCfg) instead.
  placeRings(mem, 0'u64, queueIdx)

proc virtqueueAddBuf*(vq: var Virtqueue; buf: pointer; len: uint32;
                      writable: bool): uint16 =
  ## Post one buffer to the queue. Returns the descriptor index used.
  let idx = vq.nextFree mod QueueSize.uint16
  vq.desc[idx].bufAddr  = translatePhys(buf)
  vq.desc[idx].len   = len
  vq.desc[idx].flags = if writable: VirtqDescFWrite else: 0'u16
  vq.desc[idx].next  = 0

  let availIdx = vq.avail.idx mod QueueSize.uint16
  vq.avail.ring[availIdx] = idx
  # Memory barrier: publish descriptor before bumping avail idx
  {.emit: "asm volatile(\"\" ::: \"memory\");".}
  vq.avail.idx = vq.avail.idx + 1
  vq.nextFree  = vq.nextFree + 1
  idx

proc virtqueueKick*(vq: var Virtqueue) =
  ## Notify the device that new buffers are available.
  {.emit: "asm volatile(\"\" ::: \"memory\");".}
  mmioWrite32(vq.mmioBase, VirtioRegQueueNotify, vq.queueIdx)

proc usedIdx*(vq: var Virtqueue): uint16 {.inline.} =
  ## Acquire-load the device-written used index. MUST be volatile: the device
  ## DMAs the new idx, so a hoisted/cached ordinary load would never observe it
  ## (the C optimizer can lift a plain `vq.used.idx` out of a spin loop).
  atomicLoad(addr vq.used.idx, moAcquire)

proc virtqueuePop*(vq: var Virtqueue): tuple[found: bool; id: uint32; len: uint32] =
  ## Return the next completed entry from the used ring, if any.
  if vq.lastUsed == usedIdx(vq):
    return (false, 0'u32, 0'u32)
  let elem = vq.used.ring[vq.lastUsed mod QueueSize.uint16]
  vq.lastUsed = vq.lastUsed + 1
  (true, elem.id, elem.len)
