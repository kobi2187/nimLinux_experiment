# SPDX-License-Identifier: GPL-2.0
## ping_server — userspace ELF scaffold (ring-3 PIE)
##
## Uses the kernel ABI (patched in at load time) for all I/O and IPC.
## Same ping_logic as the kernel module — only the scaffold differs.
##
## Boot sequence:
##   1. Kernel loads this as PIE, patches ABI stubs, calls appMain()
##   2. appMain creates "ping_server" (nimixChanCreate → receive capability)
##   3. Server loop: nimixCapRecv → pingLogicHandleMsg (replies as "pong" events)

import ping_logic
import nimix_entry

# ── Kernel ABI (all resolved by loader at runtime via stub patching) ──────────

proc nimixWrite(buf: pointer; len: int) {.importc, cdecl.}
proc nimixExit(code: int) {.importc, cdecl, noreturn.}
proc nimixChanCreate(name: cstring): uint64 {.importc, cdecl.}
proc nimixCapRecv(tok: uint64; buf: pointer; len: int): int {.importc, cdecl.}
proc nimixYield() {.importc, cdecl.}
proc nimixEventPublish(topic: cstring; data: pointer; dataLen: int) {.importc, cdecl.}

# ── Helpers ───────────────────────────────────────────────────────────────────

proc writeStr(s: string) =
  if s.len > 0: nimixWrite(unsafeAddr s[0], s.len)

proc writeCStr(s: cstring) =
  var i = 0
  while s[i] != '\0': inc i
  if i > 0: nimixWrite(cast[pointer](s), i)

# ── PingServerIface wired to kernel ABI ───────────────────────────────────────

proc elfLog(msg: cstring) {.nimcall.} =
  writeCStr("[ping_server_elf] ")
  writeCStr(msg)
  var nl = '\n'
  nimixWrite(addr nl, 1)

proc elfPublish(topic: cstring; data: pointer; dataLen: int) {.nimcall.} =
  nimixEventPublish(topic, data, dataLen)

proc elfPutChar(c: char) {.nimcall.} =
  nimixWrite(unsafeAddr c, 1)

# ── Module-level state ────────────────────────────────────────────────────────

var ps: PingServer
var msgBuf:  array[256, byte]

# ── Entry point ───────────────────────────────────────────────────────────────

proc appMain*() {.exportc.} =
  nimixAppInit()   # module init first: --noMain skips it (nimix_entry)
  let iface = PingServerIface(
    log:     elfLog,
    publish: elfPublish,
    putChar: elfPutChar,
  )
  pingLogicInit(ps, iface)

  # Own the channel (microkernel: the server creates its endpoint and
  # receives through the capability). In kernel models that already run the
  # ping kmod the name is taken — then this ELF is redundant and exits.
  let recvCap = nimixChanCreate(PingServerName)
  if recvCap == 0:
    writeStr("ping_server_elf: 'ping_server' already served (kmod) - exiting\n")
    nimixExit(1)
  writeStr("ping_server_elf: ready on 'ping_server'\n")

  # Replies go out as "pong" events from pingLogicHandleMsg (elfPublish).
  while true:
    let n = nimixCapRecv(recvCap, addr msgBuf[0], msgBuf.len)
    if n > 0: pingLogicHandleMsg(ps, addr msgBuf[0], n)
    else: nimixYield()   # idle: give the CPU away
