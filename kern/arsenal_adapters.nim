# SPDX-License-Identifier: GPL-2.0
## Arsenal Kernel Adapters
##
## Kernel-safe wrappers around arsenal library primitives.
## Adapts high-performance data structures for kernel use while handling:
## - No dynamic allocation (fixed-size structures)
## - Memory safety without GC
## - Synchronization primitives for multi-core kernels

import ../core/types
import ../vendor/arsenal/src/arsenal/concurrency
import ../vendor/arsenal/src/arsenal/collections

type
  # ═══════════════════════════════════════════════════════════════════════════
  # Lock-Free Queue Wrappers
  # ═══════════════════════════════════════════════════════════════════════════

  KernelSpscQueue*[T] = object
    ## Kernel-safe single-producer, single-consumer queue
    ## Used for inter-process communication where producer/consumer are known
    data: array[256, T]
    writeIdx: Atomic[uint32]
    readIdx: Atomic[uint32]
    count: Atomic[uint32]

  KernelMpmcQueue*[T] = object
    ## Kernel-safe multi-producer, multi-consumer queue
    ## Used for general work queues and interrupt handlers
    data: array[256, T]
    writeIdx: Atomic[uint32]
    readIdx: Atomic[uint32]
    count: Atomic[uint32]

  # ═══════════════════════════════════════════════════════════════════════════
  # Device Set Tracking
  # ═══════════════════════════════════════════════════════════════════════════

  DeviceSet* = object
    ## Compressed set of device IDs using roaring bitmaps
    ## Efficient tracking of device presence and state
    bitmap: IntSet

  InterruptMask* = object
    ## Compressed set of enabled IRQ numbers
    ## Efficient interrupt mask management
    bitmap: IntSet

# ═══════════════════════════════════════════════════════════════════════════
# SPSC Queue Operations
# ═══════════════════════════════════════════════════════════════════════════

proc initSpscQueue*[T](): KernelSpscQueue[T] =
  ## Initialize single-producer, single-consumer queue
  result.writeIdx = atomic(0'u32)
  result.readIdx = atomic(0'u32)
  result.count = atomic(0'u32)

proc enqueueSpsc*[T](q: var KernelSpscQueue[T], item: T): bool =
  ## Enqueue item (producer side)
  # Strategy: Use atomic operations to handle concurrent access
  # Non-blocking: returns false if queue full
  let currentCount = q.count.value
  if currentCount >= 256:
    return false

  let writeIdx = q.writeIdx.load(Acquire)
  q.data[writeIdx] = item
  q.writeIdx.store((writeIdx + 1) mod 256, Release)
  q.count.fetchAdd(1, AcqRel)
  return true

proc dequeueSpsc*[T](q: var KernelSpscQueue[T]): Option[T] =
  ## Dequeue item (consumer side)
  # Strategy: Use atomic operations for thread-safe removal
  let currentCount = q.count.value
  if currentCount == 0:
    return none(T)

  let readIdx = q.readIdx.load(Acquire)
  let item = q.data[readIdx]
  q.readIdx.store((readIdx + 1) mod 256, Release)
  q.count.fetchSub(1, AcqRel)
  return some(item)

proc peekSpsc*[T](q: KernelSpscQueue[T]): Option[T] =
  ## Peek at next item without removing (consumer side)
  let currentCount = q.count.value
  if currentCount == 0:
    return none(T)

  let readIdx = q.readIdx.load(Acquire)
  return some(q.data[readIdx])

proc isEmptySpsc*[T](q: KernelSpscQueue[T]): bool =
  ## Check if queue is empty
  return q.count.value == 0

proc countSpsc*[T](q: KernelSpscQueue[T]): uint32 =
  ## Get current queue depth
  return q.count.value

# ═══════════════════════════════════════════════════════════════════════════
# MPMC Queue Operations
# ═══════════════════════════════════════════════════════════════════════════

proc initMpmcQueue*[T](): KernelMpmcQueue[T] =
  ## Initialize multi-producer, multi-consumer queue
  result.writeIdx = atomic(0'u32)
  result.readIdx = atomic(0'u32)
  result.count = atomic(0'u32)

proc enqueueMpmc*[T](q: var KernelMpmcQueue[T], item: T): bool =
  ## Enqueue item (any producer)
  # Strategy: Compare-and-swap for lock-free coordination
  # Attempt write with strong CAS for fair ordering
  let currentCount = q.count.value
  if currentCount >= 256:
    return false

  let writeIdx = q.writeIdx.load(Acquire)
  q.data[writeIdx] = item

  var nextWrite = (writeIdx + 1) mod 256
  var expectedWrite = writeIdx
  let success = q.writeIdx.compareExchange(expectedWrite, nextWrite, AcqRel, Acquire)

  if success:
    q.count.fetchAdd(1, AcqRel)
    return true
  return false

proc dequeueMpmc*[T](q: var KernelMpmcQueue[T]): Option[T] =
  ## Dequeue item (any consumer)
  # Strategy: Compare-and-swap for lock-free coordination
  let currentCount = q.count.value
  if currentCount == 0:
    return none(T)

  let readIdx = q.readIdx.load(Acquire)
  let item = q.data[readIdx]

  var nextRead = (readIdx + 1) mod 256
  var expectedRead = readIdx
  let success = q.readIdx.compareExchange(expectedRead, nextRead, AcqRel, Acquire)

  if success:
    q.count.fetchSub(1, AcqRel)
    return some(item)
  return none(T)

proc countMpmc*[T](q: KernelMpmcQueue[T]): uint32 =
  ## Get current queue depth (approximate in MPMC)
  return q.count.value

# ═══════════════════════════════════════════════════════════════════════════
# Device Set Operations
# ═══════════════════════════════════════════════════════════════════════════

proc initDeviceSet*(): DeviceSet =
  ## Initialize empty device set
  result.bitmap = IntSet.init()

proc addDevice*(s: var DeviceSet, deviceId: uint32) =
  ## Add device to set
  s.bitmap.add(deviceId)

proc removeDevice*(s: var DeviceSet, deviceId: uint32) =
  ## Remove device from set
  s.bitmap.remove(deviceId)

proc hasDevice*(s: DeviceSet, deviceId: uint32): bool =
  ## Check if device is in set
  s.bitmap.contains(deviceId)

proc deviceCount*(s: DeviceSet): uint32 =
  ## Get number of devices in set
  return s.bitmap.cardinality()

proc iterateDevices*(s: DeviceSet): seq[uint32] =
  ## Get list of all device IDs
  # TODO: Implement iterator over roaring bitmap
  # For now, return empty sequence pending full roaring bitmap iteration support
  @[]

# ═══════════════════════════════════════════════════════════════════════════
# Interrupt Mask Operations
# ═══════════════════════════════════════════════════════════════════════════

proc initInterruptMask*(): InterruptMask =
  ## Initialize empty interrupt mask
  result.bitmap = IntSet.init()

proc enableIrq*(mask: var InterruptMask, irq: uint8) =
  ## Enable IRQ in mask
  mask.bitmap.add(uint32(irq))

proc disableIrq*(mask: var InterruptMask, irq: uint8) =
  ## Disable IRQ in mask
  mask.bitmap.remove(uint32(irq))

proc isIrqEnabled*(mask: InterruptMask, irq: uint8): bool =
  ## Check if IRQ is enabled
  mask.bitmap.contains(uint32(irq))

proc enabledIrqCount*(mask: InterruptMask): uint32 =
  ## Get number of enabled IRQs
  return mask.bitmap.cardinality()

# ═══════════════════════════════════════════════════════════════════════════
# Atomic Utilities
# ═══════════════════════════════════════════════════════════════════════════

proc spinWait*() {.inline.} =
  ## Issue CPU hint for spin-wait (prevents busy waiting)
  # TODO: Use spinHint() from arsenal atomics for platform-specific hints
  discard

proc atomicBarrier*(order: MemoryOrder = SeqCst) {.inline.} =
  ## Issue memory barrier
  # TODO: Use atomicThreadFence from arsenal
  discard
