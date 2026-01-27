# SPDX-License-Identifier: GPL-2.0
## Atomic Operations - LAYER 0
##
## Low-level atomic operations for synchronization primitives.
## These map to CPU-specific atomic instructions.

type
  MemoryOrder* = enum
    ## Memory ordering constraints
    moRelaxed       ## No ordering constraints
    moConsume       ## Consume ordering (data-dependent)
    moAcquire       ## Acquire - loads after can't move before
    moRelease       ## Release - stores before can't move after
    moAcqRel        ## Acquire-Release combined
    moSeqCst        ## Sequential consistency (strongest)

# ═══════════════════════════════════════════════════════════════════════════
# Compiler/Memory Barriers
# ═══════════════════════════════════════════════════════════════════════════

proc compilerBarrier*() {.inline.} =
  ## Prevent compiler reordering across this point
  {.emit: """asm volatile("" ::: "memory");""".}

proc memoryBarrier*() {.inline.} =
  ## Full memory barrier (CPU fence)
  when defined(amd64) or defined(x86_64):
    {.emit: """asm volatile("mfence" ::: "memory");""".}
  elif defined(arm64) or defined(aarch64):
    {.emit: """asm volatile("dmb ish" ::: "memory");""".}
  else:
    {.emit: """__sync_synchronize();""".}

proc readBarrier*() {.inline.} =
  ## Read memory barrier
  when defined(amd64) or defined(x86_64):
    {.emit: """asm volatile("lfence" ::: "memory");""".}
  elif defined(arm64) or defined(aarch64):
    {.emit: """asm volatile("dmb ishld" ::: "memory");""".}
  else:
    {.emit: """__sync_synchronize();""".}

proc writeBarrier*() {.inline.} =
  ## Write memory barrier
  when defined(amd64) or defined(x86_64):
    {.emit: """asm volatile("sfence" ::: "memory");""".}
  elif defined(arm64) or defined(aarch64):
    {.emit: """asm volatile("dmb ishst" ::: "memory");""".}
  else:
    {.emit: """__sync_synchronize();""".}

# ═══════════════════════════════════════════════════════════════════════════
# Atomic Load/Store
# ═══════════════════════════════════════════════════════════════════════════

proc atomicLoad*[T: SomeInteger](p: ptr T, order: MemoryOrder = moSeqCst): T {.inline.} =
  ## Atomic load with specified memory ordering
  when defined(amd64) or defined(x86_64):
    # x86 loads are naturally atomic for aligned data
    result = p[]
    if order == moSeqCst or order == moAcquire:
      compilerBarrier()
  else:
    {.emit: [result, " = __atomic_load_n(", p, ", ", ord(order), ");"].}

proc atomicStore*[T: SomeInteger](p: ptr T, val: T, order: MemoryOrder = moSeqCst) {.inline.} =
  ## Atomic store with specified memory ordering
  when defined(amd64) or defined(x86_64):
    if order == moSeqCst:
      # Use xchg for seq_cst (implied lock prefix)
      {.emit: ["""asm volatile("xchg %0, %1" : "+r" (""", val, """), "+m" (*""", p, """) :: "memory");"""].}
    else:
      if order == moRelease:
        compilerBarrier()
      p[] = val
      if order == moSeqCst:
        compilerBarrier()
  else:
    {.emit: ["__atomic_store_n(", p, ", ", val, ", ", ord(order), ");"].}

# ═══════════════════════════════════════════════════════════════════════════
# Atomic Exchange
# ═══════════════════════════════════════════════════════════════════════════

proc atomicExchange*[T: SomeInteger](p: ptr T, val: T, order: MemoryOrder = moSeqCst): T {.inline.} =
  ## Atomically exchange value, return old value
  when defined(amd64) or defined(x86_64):
    result = val
    when sizeof(T) == 1:
      {.emit: ["""asm volatile("xchgb %0, %1" : "+r" (""", result, """), "+m" (*""", p, """) :: "memory");"""].}
    elif sizeof(T) == 2:
      {.emit: ["""asm volatile("xchgw %0, %1" : "+r" (""", result, """), "+m" (*""", p, """) :: "memory");"""].}
    elif sizeof(T) == 4:
      {.emit: ["""asm volatile("xchgl %0, %1" : "+r" (""", result, """), "+m" (*""", p, """) :: "memory");"""].}
    elif sizeof(T) == 8:
      {.emit: ["""asm volatile("xchgq %0, %1" : "+r" (""", result, """), "+m" (*""", p, """) :: "memory");"""].}
  else:
    {.emit: [result, " = __atomic_exchange_n(", p, ", ", val, ", ", ord(order), ");"].}

# ═══════════════════════════════════════════════════════════════════════════
# Atomic Compare and Exchange
# ═══════════════════════════════════════════════════════════════════════════

proc atomicCompareExchange*[T: SomeInteger](
  p: ptr T,
  expected: ptr T,
  desired: T,
  successOrder: MemoryOrder = moSeqCst,
  failureOrder: MemoryOrder = moSeqCst
): bool {.inline.} =
  ## Compare and exchange. Returns true if exchange succeeded.
  ## On failure, expected is updated with the current value.
  when defined(amd64) or defined(x86_64):
    var exp = expected[]
    var success: bool
    when sizeof(T) == 1:
      {.emit: ["""
        asm volatile("lock cmpxchgb %2, %1"
          : "=a" (""", exp, """), "+m" (*""", p, """)
          : "r" (""", desired, """), "0" (""", exp, """)
          : "memory");
        """, success, " = (", exp, " == ", expected[], ");"].}
    elif sizeof(T) == 2:
      {.emit: ["""
        asm volatile("lock cmpxchgw %2, %1"
          : "=a" (""", exp, """), "+m" (*""", p, """)
          : "r" (""", desired, """), "0" (""", exp, """)
          : "memory");
        """, success, " = (", exp, " == ", expected[], ");"].}
    elif sizeof(T) == 4:
      {.emit: ["""
        asm volatile("lock cmpxchgl %2, %1"
          : "=a" (""", exp, """), "+m" (*""", p, """)
          : "r" (""", desired, """), "0" (""", exp, """)
          : "memory");
        """, success, " = (", exp, " == ", expected[], ");"].}
    elif sizeof(T) == 8:
      {.emit: ["""
        asm volatile("lock cmpxchgq %2, %1"
          : "=a" (""", exp, """), "+m" (*""", p, """)
          : "r" (""", desired, """), "0" (""", exp, """)
          : "memory");
        """, success, " = (", exp, " == ", expected[], ");"].}
    expected[] = exp
    result = success
  else:
    {.emit: [result, " = __atomic_compare_exchange_n(", p, ", ", expected, ", ", desired, ", 0, ", ord(successOrder), ", ", ord(failureOrder), ");"].}

proc atomicCompareExchangeWeak*[T: SomeInteger](
  p: ptr T,
  expected: ptr T,
  desired: T,
  successOrder: MemoryOrder = moSeqCst,
  failureOrder: MemoryOrder = moSeqCst
): bool {.inline.} =
  ## Weak compare and exchange (may fail spuriously)
  atomicCompareExchange(p, expected, desired, successOrder, failureOrder)

# ═══════════════════════════════════════════════════════════════════════════
# Atomic Fetch-and-Op
# ═══════════════════════════════════════════════════════════════════════════

proc atomicFetchAdd*[T: SomeInteger](p: ptr T, val: T, order: MemoryOrder = moSeqCst): T {.inline.} =
  ## Atomically add and return old value
  when defined(amd64) or defined(x86_64):
    result = val
    when sizeof(T) == 1:
      {.emit: ["""asm volatile("lock xaddb %0, %1" : "+r" (""", result, """), "+m" (*""", p, """) :: "memory");"""].}
    elif sizeof(T) == 2:
      {.emit: ["""asm volatile("lock xaddw %0, %1" : "+r" (""", result, """), "+m" (*""", p, """) :: "memory");"""].}
    elif sizeof(T) == 4:
      {.emit: ["""asm volatile("lock xaddl %0, %1" : "+r" (""", result, """), "+m" (*""", p, """) :: "memory");"""].}
    elif sizeof(T) == 8:
      {.emit: ["""asm volatile("lock xaddq %0, %1" : "+r" (""", result, """), "+m" (*""", p, """) :: "memory");"""].}
  else:
    {.emit: [result, " = __atomic_fetch_add(", p, ", ", val, ", ", ord(order), ");"].}

proc atomicFetchSub*[T: SomeInteger](p: ptr T, val: T, order: MemoryOrder = moSeqCst): T {.inline.} =
  ## Atomically subtract and return old value
  when T is SomeSignedInt:
    atomicFetchAdd(p, -val, order)
  else:
    atomicFetchAdd(p, cast[T](0 - cast[int64](val)), order)

proc atomicFetchOr*[T: SomeInteger](p: ptr T, val: T, order: MemoryOrder = moSeqCst): T {.inline.} =
  ## Atomically OR and return old value
  {.emit: [result, " = __atomic_fetch_or(", p, ", ", val, ", ", ord(order), ");"].}

proc atomicFetchAnd*[T: SomeInteger](p: ptr T, val: T, order: MemoryOrder = moSeqCst): T {.inline.} =
  ## Atomically AND and return old value
  {.emit: [result, " = __atomic_fetch_and(", p, ", ", val, ", ", ord(order), ");"].}

proc atomicFetchXor*[T: SomeInteger](p: ptr T, val: T, order: MemoryOrder = moSeqCst): T {.inline.} =
  ## Atomically XOR and return old value
  {.emit: [result, " = __atomic_fetch_xor(", p, ", ", val, ", ", ord(order), ");"].}

# ═══════════════════════════════════════════════════════════════════════════
# Atomic Add/Sub (return new value)
# ═══════════════════════════════════════════════════════════════════════════

proc atomicAddFetch*[T: SomeInteger](p: ptr T, val: T, order: MemoryOrder = moSeqCst): T {.inline.} =
  ## Atomically add and return new value
  atomicFetchAdd(p, val, order) + val

proc atomicSubFetch*[T: SomeInteger](p: ptr T, val: T, order: MemoryOrder = moSeqCst): T {.inline.} =
  ## Atomically subtract and return new value
  atomicFetchSub(p, val, order) - val

# ═══════════════════════════════════════════════════════════════════════════
# CPU Pause/Yield
# ═══════════════════════════════════════════════════════════════════════════

proc cpuPause*() {.inline.} =
  ## CPU pause hint for spin loops
  when defined(amd64) or defined(x86_64):
    {.emit: """asm volatile("pause" ::: "memory");""".}
  elif defined(arm64) or defined(aarch64):
    {.emit: """asm volatile("yield" ::: "memory");""".}
  else:
    compilerBarrier()

# Alias for spin-wait loops
proc pause*() {.inline.} = cpuPause()
