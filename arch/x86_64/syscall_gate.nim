# SPDX-License-Identifier: GPL-2.0
## Syscall Gate — ring 0↔3 transition
##
## Calling convention (NimixOS ABI):
##   RAX = syscall number (NimixSyscall ordinal)
##   RDI = arg0, RSI = arg1, RDX = arg2, R10 = arg3
##   Return value in RAX.
##
## syscall_entry in boot_asm.S:
##   saves user RSP → syscallScratchRsp global
##   loads kernel RSP from TSS.rsp0
##   calls syscallDispatch(nr, a0, a1, a2, a3)
##   restores user RSP, sysretq
##
## MSR layout (AMD64 Vol 2 §6.1.1):
##   STAR[47:32] = KernelCS  → CS on syscall entry
##   STAR[63:48] = UserDS-8  → CS/SS on sysret
##   LSTAR       = syscall_entry RIP
##   SFMASK      = clears IF on entry (bit 9)

import ./cpu_primitives
import ./tss
import ../../kernel/abi/nimix_abi as abiMod

# Scratch slot: user RSP saved here on syscall entry, restored before sysretq.
# Single-CPU only — safe as a plain global. Exported so boot_asm.S can access.
var syscallScratchRsp* {.exportc: "syscallScratchRsp".}: uint64

# ── Syscall number enum ───────────────────────────────────────────────────────
# Ordinals MUST stay in sync with NimixAbiVTable field order and with
# the numbers baked into app trampolines by the ELF loader.

type NimixSyscall* = enum
  scWrite          =  0
  scExit           =  1
  scAllocRegion    =  2
  scFreeRegion     =  3
  scChanSend       =  4
  scChanRecv       =  5
  scEventPublish   =  6
  scEventSubscribe =  7
  scEventPoll      =  8
  scGetArgs        =  9
  scProcList       = 10
  scSchedStats     = 11
  scProcKillPid    = 12
  scFsReadDir      = 13
  scFsRead         = 14
  scFsWrite        = 15
  scCapSend        = 16
  scChanCall       = 17
  scSleep          = 18
  scYield          = 19
  scSysInfo        = 20
  scGrantRegion    = 21
  scUptimeSecs     = 22
  scWallClock      = 23
  scMapAnon        = 24
  scFreeAnon       = 25
  scSndPlay        = 26

const NimixSyscallCount* = 27   ## total number of syscalls

# ── Dispatch table ────────────────────────────────────────────────────────────
# Raw function pointers indexed by NimixSyscall ordinal.
# Filled at boot by syscallTableInit(); called directly from syscall_entry asm.
var syscallTable* {.exportc: "syscallTable".}: array[NimixSyscallCount, uint64]

proc syscallTableInit*() =
  ## Populate syscallTable from the live nimixAbi vtable.
  ## Call after wireSharedAbi() has filled nimixAbi.
  let v = abiMod.nimixAbi
  syscallTable[ 0] = cast[uint64](v.write)
  syscallTable[ 1] = cast[uint64](v.exit)
  syscallTable[ 2] = cast[uint64](v.allocRegion)
  syscallTable[ 3] = cast[uint64](v.freeRegion)
  syscallTable[ 4] = cast[uint64](v.chanSend)
  syscallTable[ 5] = cast[uint64](v.chanRecv)
  syscallTable[ 6] = cast[uint64](v.eventPublish)
  syscallTable[ 7] = cast[uint64](v.eventSubscribe)
  syscallTable[ 8] = cast[uint64](v.eventPoll)
  syscallTable[ 9] = cast[uint64](v.getArgs)
  syscallTable[10] = cast[uint64](v.procList)
  syscallTable[11] = cast[uint64](v.schedStats)
  syscallTable[12] = cast[uint64](v.procKillPid)
  syscallTable[13] = cast[uint64](v.fsReadDir)
  syscallTable[14] = cast[uint64](v.fsRead)
  syscallTable[15] = cast[uint64](v.fsWrite)
  syscallTable[16] = cast[uint64](v.capSend)
  syscallTable[17] = cast[uint64](v.chanCall)
  syscallTable[18] = cast[uint64](v.sleep)
  syscallTable[19] = cast[uint64](v.`yield`)
  syscallTable[20] = cast[uint64](v.sysInfo)
  syscallTable[21] = cast[uint64](v.grantRegion)
  syscallTable[22] = cast[uint64](v.uptimeSecs)
  syscallTable[23] = cast[uint64](v.wallClock)
  syscallTable[24] = cast[uint64](v.mapAnon)
  syscallTable[25] = cast[uint64](v.freeAnon)
  syscallTable[26] = cast[uint64](v.sndPlay)

proc syscallDispatch*(nr, a0, a1, a2, a3: uint64): uint64 {.exportc: "syscallDispatch", cdecl.} =
  ## Called from syscall_entry asm stub. Dispatches by nr through syscallTable.
  ## Returns result in RAX (Nim cdecl convention on x86-64).
  if nr >= NimixSyscallCount: return high(uint64)
  let fn = syscallTable[nr]
  if fn == 0: return high(uint64)
  type Fn5 = proc(a0, a1, a2, a3, a4: uint64): uint64 {.cdecl.}
  cast[Fn5](fn)(a0, a1, a2, a3, 0)

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

# syscall_entry is implemented in boot_asm.S; imported here for LSTAR wiring.
proc syscall_entry() {.importc: "syscall_entry", cdecl.}

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
  writeMsr(MSR_LSTAR,  cast[uint64](syscall_entry))
  writeMsr(MSR_SFMASK, 0x200'u64)  # clear IF on syscall entry

  # 6. Enable syscall/sysret in EFER
  let efer = readMsr(MSR_EFER)
  writeMsr(MSR_EFER, efer or EFER_SCE)

  # 7. Populate the dispatch table from the live ABI vtable
  syscallTableInit()

