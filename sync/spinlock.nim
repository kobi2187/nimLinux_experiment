# SPDX-License-Identifier: GPL-2.0
## SpinLock - LAYER 3
##
## Basic spinlock implementation for kernel synchronization.
## No dependencies beyond arch primitives.

import ../arch/common/atomics

when defined(amd64) or defined(x86_64):
  import ../arch/x86_64/cpu_primitives

type
  # ═══════════════════════════════════════════════════════════════════════════
  # SpinLock
  # ═══════════════════════════════════════════════════════════════════════════

  SpinLock* = object
    ## Basic spinlock
    ## Uses test-and-set with backoff
    locked: uint32

  SpinLockGuard* = object
    ## RAII guard for spinlock with interrupt state
    lock: ptr SpinLock
    irqState: uint64

# ═══════════════════════════════════════════════════════════════════════════
# SpinLock Implementation
# ═══════════════════════════════════════════════════════════════════════════

proc init*(lock: var SpinLock) {.inline.} =
  ## Initialize spinlock to unlocked state
  lock.locked = 0

proc acquire*(lock: var SpinLock) {.inline.} =
  ## Acquire spinlock, spinning until available
  while atomicExchange(addr lock.locked, 1'u32) == 1:
    # Spin with pause to reduce bus contention
    while atomicLoad(addr lock.locked) == 1:
      pause()

proc release*(lock: var SpinLock) {.inline.} =
  ## Release spinlock
  atomicStore(addr lock.locked, 0'u32, moRelease)

proc tryAcquire*(lock: var SpinLock): bool {.inline.} =
  ## Try to acquire spinlock without blocking
  ## Returns true if lock was acquired
  atomicExchange(addr lock.locked, 1'u32) == 0

proc isLocked*(lock: SpinLock): bool {.inline.} =
  ## Check if lock is currently held (for debugging)
  atomicLoad(addr lock.locked) != 0

# ═══════════════════════════════════════════════════════════════════════════
# SpinLock with Interrupt Disable
# ═══════════════════════════════════════════════════════════════════════════

proc acquireIrqSave*(lock: var SpinLock): SpinLockGuard {.inline.} =
  ## Acquire lock and disable interrupts
  ## Returns guard that will restore state on release
  when defined(amd64) or defined(x86_64):
    result.irqState = disableInterrupts()
  else:
    result.irqState = 0
  result.lock = addr lock
  lock.acquire()

proc release*(guard: var SpinLockGuard) {.inline.} =
  ## Release lock and restore interrupt state
  guard.lock[].release()
  when defined(amd64) or defined(x86_64):
    restoreInterrupts(guard.irqState)

proc acquireIrq*(lock: var SpinLock) {.inline.} =
  ## Acquire lock with interrupts disabled (no state save)
  when defined(amd64) or defined(x86_64):
    cli()
  lock.acquire()

proc releaseIrq*(lock: var SpinLock) {.inline.} =
  ## Release lock and enable interrupts
  lock.release()
  when defined(amd64) or defined(x86_64):
    sti()

# ═══════════════════════════════════════════════════════════════════════════
# Template Helpers
# ═══════════════════════════════════════════════════════════════════════════

template withLock*(lock: var SpinLock, body: untyped) =
  ## Execute body while holding lock
  lock.acquire()
  try:
    body
  finally:
    lock.release()

template withLockIrqSave*(lock: var SpinLock, body: untyped) =
  ## Execute body while holding lock with interrupts disabled
  var guard = lock.acquireIrqSave()
  try:
    body
  finally:
    guard.release()

# ═══════════════════════════════════════════════════════════════════════════
# Ticket SpinLock (fairer, FIFO ordering)
# ═══════════════════════════════════════════════════════════════════════════

type
  TicketLock* = object
    ## Ticket-based spinlock with FIFO ordering
    ## Fairer but slightly more overhead than basic spinlock
    nextTicket: uint32
    nowServing: uint32

proc init*(lock: var TicketLock) {.inline.} =
  ## Initialize ticket lock
  lock.nextTicket = 0
  lock.nowServing = 0

proc acquire*(lock: var TicketLock) {.inline.} =
  ## Acquire ticket lock
  let myTicket = atomicFetchAdd(addr lock.nextTicket, 1'u32)
  while atomicLoad(addr lock.nowServing) != myTicket:
    pause()

proc release*(lock: var TicketLock) {.inline.} =
  ## Release ticket lock
  discard atomicFetchAdd(addr lock.nowServing, 1'u32)

proc tryAcquire*(lock: var TicketLock): bool {.inline.} =
  ## Try to acquire ticket lock
  let current = atomicLoad(addr lock.nowServing)
  var expected = current
  atomicCompareExchange(addr lock.nextTicket, addr expected, current + 1)

template withLock*(lock: var TicketLock, body: untyped) =
  ## Execute body while holding ticket lock
  lock.acquire()
  try:
    body
  finally:
    lock.release()

# ═══════════════════════════════════════════════════════════════════════════
# RawSpinLock (minimal, for very low-level use)
# ═══════════════════════════════════════════════════════════════════════════

type
  RawSpinLock* = distinct uint32
    ## Minimal spinlock as distinct type

proc init*(lock: var RawSpinLock) {.inline.} =
  uint32(lock) = 0

proc acquire*(lock: var RawSpinLock) {.inline.} =
  while atomicExchange(cast[ptr uint32](addr lock), 1'u32) == 1:
    while atomicLoad(cast[ptr uint32](addr lock)) == 1:
      pause()

proc release*(lock: var RawSpinLock) {.inline.} =
  atomicStore(cast[ptr uint32](addr lock), 0'u32, moRelease)
