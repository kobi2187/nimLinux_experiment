# SPDX-License-Identifier: GPL-2.0
## ping_server — userspace ELF scaffold (microkernel / future ring-3)
##
## Same ping_logic, different scaffold: uses kernel ABI procs for I/O,
## compiled as PIE so the loader can place it anywhere in the address space.
##
## Build with: make nim-apps target (--os:standalone, -pie)
## The kernel loads this via elfLoad() + relocations, then calls appMain().

import ping_logic

# ── Kernel ABI imports (resolved by loader at runtime) ────────────────────────

proc nimixWrite(buf: pointer; len: int) {.importc, cdecl.}
proc nimixExit(code: int) {.importc, cdecl, noreturn.}

# ── Minimal IPC stubs — will call capability handles once that layer exists ───
# For now: no-ops so the server can be compiled and linked today.

proc stubPublish(topic: cstring; data: pointer; dataLen: int) {.nimcall.} =
  # TODO: replace with capability IPC call to event server
  discard

proc stubPutChar(c: char) {.nimcall.} =
  nimixWrite(unsafeAddr c, 1)

proc stubLog(msg: cstring) {.nimcall.} =
  var i = 0
  while msg[i] != '\0':
    stubPutChar(msg[i])
    inc i
  stubPutChar('\n')

# ── Entry point ───────────────────────────────────────────────────────────────

var ps: PingServer

proc appMain*() {.exportc.} =
  let iface = PingServerIface(
    log:     stubLog,
    publish: stubPublish,
    putChar: stubPutChar,
  )
  pingLogicInit(ps, iface)

  # Server loop — blocks until kernel terminates us
  # (real implementation would block on IPC recv, not spin)
  while true:
    discard  # TODO: recv from capability channel, call pingLogicHandleMsg
