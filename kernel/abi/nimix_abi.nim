# SPDX-License-Identifier: GPL-2.0
## NimixOS App ABI — the minimal kernel surface exposed to userspace apps.
##
## This is the ONLY interface between a compiled Nim app (--os:standalone)
## and the kernel. Four procs, dispatched through a vtable so the same
## app binary works across kernel models.
##
## The vtable is set during kernel init (same pattern as scheduler/ipc).
## Apps call these via importc from the C ABI header.

type
  NimixAbiVTable* = object
    ## Kernel-side implementations assigned at boot by each model's init.
    allocRegion*: proc(size: int): pointer {.nimcall.}
      ## Allocate `size` bytes. In SASOS: carve from next free region.
      ## In process model: allocate from per-process heap.

    freeRegion*: proc(p: pointer; size: int) {.nimcall.}
      ## Release memory previously returned by allocRegion.

    write*: proc(buf: pointer; len: int) {.nimcall.}
      ## Write `len` bytes from `buf` to the app's stdout (VGA + serial).

    exit*: proc(code: int) {.nimcall.}
      ## Terminate the calling app/SIP. Never returns.

var nimixAbi*: NimixAbiVTable
  ## Global ABI vtable. Set once at boot; read-only after that.

# ── C-ABI bridge ─────────────────────────────────────────────────────────────
# These are the symbols apps link against. They simply forward to the vtable.
# Declared with exportc so the linker sees them as plain C symbols.

proc nimixAllocRegion*(size: int): pointer {.exportc, cdecl.} =
  nimixAbi.allocRegion(size)

proc nimixFreeRegion*(p: pointer; size: int) {.exportc, cdecl.} =
  nimixAbi.freeRegion(p, size)

proc nimixWrite*(buf: pointer; len: int) {.exportc, cdecl.} =
  nimixAbi.write(buf, len)

proc nimixExit*(code: int) {.exportc, cdecl.} =
  nimixAbi.exit(code)
  while true: discard  # unreachable; silences noreturn requirement
