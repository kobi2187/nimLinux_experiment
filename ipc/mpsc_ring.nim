# SPDX-License-Identifier: GPL-2.0
## Lock-Free Multi-Producer Single-Consumer (MPSC) Bounded Ring Buffer
## =====================================================================
##
## SMP-safe, zero-allocation, lock-free queue for actor mailboxes and server channels.
## Backed by Dmitry Vyukov's MPMC queue algorithm, optimized for single-consumer.
## Kernel-safe: no stdlib dependencies, compiles under --os:any.

import ../arch/common/atomics

type
  MpscSlot*[T] = object
    sequence*: uint64
    data*: T

  MpscQueue*[N: static int; T] = object
    ## Bounded MPSC lock-free queue. N MUST be a power of 2.
    buffer*: array[N, MpscSlot[T]]
    enqueuePos*: uint64
    dequeuePos*: uint64
    mask: uint64

proc mpscInit*[N, T](q: var MpscQueue[N, T]) =
  ## Initialize the queue and set up slot sequence numbers.
  # Validate power of 2
  static:
    doAssert (N and (N - 1)) == 0, "MPSC Queue size must be a power of 2"
  
  q.enqueuePos = 0
  q.dequeuePos = 0
  q.mask = uint64(N - 1)
  for i in 0..<N:
    q.buffer[i].sequence = uint64(i)

proc mpscEnqueue*[N, T](q: var MpscQueue[N, T]; data: T): bool =
  ## Atomically enqueue an item. Multi-producer safe (lock-free).
  ## Returns false if the queue is full.
  var pos = atomicLoad(addr q.enqueuePos, moRelaxed)
  
  while true:
    let slotIdx = int(pos and q.mask)
    let slot = addr q.buffer[slotIdx]
    let seq = atomicLoad(addr slot.sequence, moAcquire)
    let diff = int64(seq) - int64(pos)
    
    if diff == 0:
      # Slot is ready for writing. Try to claim it.
      var expected = pos
      if atomicCompareExchange(addr q.enqueuePos, addr expected, pos + 1, moRelaxed, moRelaxed):
        # Claimed successfully! Write data and release.
        slot.data = data
        atomicStore(addr slot.sequence, pos + 1, moRelease)
        return true
      # CAS failed: expected has been updated to current enqueuePos. Retry.
      pos = expected
    elif diff < 0:
      # Queue is full
      return false
    else:
      # Slot is being read/wrapped. Reload pos and try again.
      pos = atomicLoad(addr q.enqueuePos, moRelaxed)

proc mpscDequeue*[N, T](q: var MpscQueue[N, T]; data: var T): bool =
  ## Dequeue the oldest item. Single-consumer safe (no locks needed on read).
  ## Returns false if the queue is empty.
  let pos = q.dequeuePos
  let slotIdx = int(pos and q.mask)
  let slot = addr q.buffer[slotIdx]
  let seq = atomicLoad(addr slot.sequence, moAcquire)
  let diff = int64(seq) - int64(pos + 1)
  
  if diff == 0:
    # Slot has data and is ready to be read.
    # Since only one consumer runs this, we don't need CAS on dequeuePos.
    q.dequeuePos = pos + 1
    data = slot.data
    # Release the slot back to producers, marking it ready for index + N
    atomicStore(addr slot.sequence, pos + uint64(N), moRelease)
    return true
  
  # Empty or producer has not finished writing to the slot yet.
  return false

proc mpscCount*[N, T](q: MpscQueue[N, T]): int =
  ## Get the approximate number of items in the queue.
  let eq = atomicLoad(unsafeAddr q.enqueuePos, moRelaxed)
  let dq = q.dequeuePos
  if eq >= dq: int(eq - dq) else: 0

proc mpscIsEmpty*[N, T](q: MpscQueue[N, T]): bool =
  ## Check if the queue is currently empty.
  atomicLoad(unsafeAddr q.enqueuePos, moRelaxed) == q.dequeuePos
