# SPDX-License-Identifier: GPL-2.0
## Syscall Gate — ring 0↔3 transition
##
## Configures the CPU so that `syscall` in ring 3 jumps to
## `syscallEntry` in ring 0, saving/restoring state correctly.
##
## MSR layout (AMD64 Vol 2, §6.1.1):
##   STAR[63:48] = user CS base  (CPU adds 16 for user CS, 8 for user DS)
##   STAR[47:32] = kernel CS     (CPU uses this for ring 0 on syscall)
##   LSTAR       = 64-bit syscall entry RIP
##   SFMASK      = RFLAGS bits to clear on syscall entry (at minimum: IF)
##
## NOTE (Phase D concern): syscallEntry is currently a minimal stub that
## returns immediately via sysretq. Full register save/restore and dispatch
## table are deferred to Phase D when actual syscalls are implemented.
## The swapgs + GS-based stack swap is also stubbed — a per-task kernel
## stack from TSS.rsp0 will be used in Phase D.

import ./cpu_primitives
import ./tss

# ─── GDT table (7 entries, patched at runtime for TSS descriptor) ───────────
#
# We declare the GDT in Nim so we own the address and can patch the TSS
# descriptor fields without needing a symbol from the asm stub.
#
# Layout:
#   [0] 0x00  Null
#   [1] 0x08  64-bit code, ring 0   (kernel CS)
#   [2] 0x10  64-bit data, ring 0   (kernel DS)
#   [3] 0x18  64-bit code, ring 3   (user CS)
#   [4] 0x20  64-bit data, ring 3   (user DS)
#   [5] 0x28  TSS descriptor low    (16-byte, filled at runtime)
#   [6] 0x30  TSS descriptor high   (upper 32 bits of base)

var gdtTable* {.exportc.}: array[7, uint64] = [
  0x0000000000000000'u64,   # [0] Null
  0x0020980000000000'u64,   # [1] 64-bit code, ring 0
  0x0000920000000000'u64,   # [2] 64-bit data, ring 0
  0x0020F80000000000'u64,   # [3] 64-bit code, ring 3
  0x0000F20000000000'u64,   # [4] 64-bit data, ring 3
  0x0000000000000000'u64,   # [5] TSS low   (filled by installTssDescriptor)
  0x0000000000000000'u64,   # [6] TSS high  (filled by installTssDescriptor)
]

# Kernel stack for syscall entry (1 page = 4096 bytes)
var kernelSyscallStack: array[4096, byte]

proc syscallEntry() {.exportc, cdecl, asmNoStackFrame.} =
  ## Minimal syscall entry stub — Phase D will add full save/restore.
  ## On entry: RCX=saved RIP, R11=saved RFLAGS.
  ## We sysretq immediately; no actual syscall dispatch yet.
  {.emit: """
    __asm__ volatile(
      "sysretq\n\t"
      ::: "memory"
    );
  """.}

proc installTssDescriptor() =
  ## Write the 16-byte TSS descriptor into GDT slots [5] and [6].
  ##
  ## TSS descriptor format (64-bit):
  ##   bits 15:0   = limit[15:0]
  ##   bits 39:16  = base[23:0]
  ##   bits 47:40  = type/DPL/P  (0x89 = Present, Type=9 = 64-bit TSS available)
  ##   bits 51:48  = limit[19:16]
  ##   bits 55:52  = flags (G=0 for byte granularity)
  ##   bits 63:56  = base[31:24]
  ##   [6] bits 31:0 = base[63:32]  (high quad-word)
  let tssAddr = cast[uint64](addr globalTss)
  let limit   = uint64(sizeof(Tss) - 1)

  let low =
    (limit and 0xFFFF) or
    ((tssAddr and 0x00FFFFFF'u64) shl 16) or
    (0x89'u64 shl 40) or
    (((limit shr 16) and 0xF) shl 48) or
    (((tssAddr shr 24) and 0xFF) shl 56)

  let high = tssAddr shr 32

  gdtTable[5] = low
  gdtTable[6] = high

proc tssInit*(kernelStackTop: uint64) =
  ## Initialise the global TSS with the kernel stack pointer.
  globalTss.rsp0         = kernelStackTop
  globalTss.ioBitmapBase = uint16(sizeof(Tss))  # disable I/O bitmap

proc syscallGateInit*() =
  ## Configure TSS, GDT, and syscall/sysret MSRs.
  ##
  ## Call order:
  ##   1. Install TSS descriptor into our Nim-owned GDT
  ##   2. Reload GDTR to point at the Nim GDT
  ##   3. Load TR
  ##   4. Write STAR/LSTAR/SFMASK MSRs and enable SCE in EFER

  # 1. Fill TSS fields
  let stackTop = cast[uint64](addr kernelSyscallStack[4095])
  tssInit(stackTop)

  # 2. Patch TSS descriptor into GDT
  installTssDescriptor()

  # 3. Reload GDTR (now points at gdtTable in Nim BSS)
  lgdt(addr gdtTable[0], uint16(sizeof(gdtTable) - 1))

  # 4. Load TR with TSS selector
  ltr(TssSelector)

  # 5. Configure syscall MSRs
  #    STAR[47:32] = KernelCS  → on syscall: CS=KernelCS, SS=KernelCS+8 (=KernelDS)
  #    STAR[63:48] = UserDS-8  → on sysret:  CS=base+16 (=UserCS), SS=base+8 (=UserDS)
  let star = (uint64(UserDS - 8) shl 48) or (uint64(KernelCS) shl 32)
  writeMsr(MSR_STAR,   star)
  writeMsr(MSR_LSTAR,  cast[uint64](syscallEntry))
  writeMsr(MSR_SFMASK, 0x200'u64)  # clear IF on syscall entry

  # 6. Enable syscall/sysret in EFER
  let efer = readMsr(MSR_EFER)
  writeMsr(MSR_EFER, efer or EFER_SCE)
