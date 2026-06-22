# SPDX-License-Identifier: GPL-2.0
## ping_server — userspace ELF scaffold (ring-3 PIE)
##
## Uses the kernel ABI (9 procs, patched in at load time) for all I/O and IPC.
## Same ping_logic as the kernel module — only the scaffold differs.
##
## Boot sequence:
##   1. Kernel loads this as PIE, patches ABI stubs, calls appMain()
##   2. appMain registers the ping_server channel via nimixChanSend (sentinel)
##      and subscribes to events via nimixEventSubscribe
##   3. Server loop: poll channel → handle message → publish pong event

import ping_logic

# ── Kernel ABI (all resolved by loader at runtime via stub patching) ──────────

proc nimixWrite(buf: pointer; len: int) {.importc, cdecl.}
proc nimixExit(code: int) {.importc, cdecl, noreturn.}
proc nimixChanRecv(name: cstring; buf: pointer; bufLen: int): int {.importc, cdecl.}
proc nimixEventPublish(topic: cstring; data: pointer; dataLen: int) {.importc, cdecl.}
proc nimixEventSubscribe(topic: cstring): uint32 {.importc, cdecl.}

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

# ── Entry point ───────────────────────────────────────────────────────────────

var ps: PingServer
var msgBuf: array[256, byte]

proc appMain*() {.exportc.} =
  let iface = PingServerIface(
    log:     elfLog,
    publish: elfPublish,
    putChar: elfPutChar,
  )
  pingLogicInit(ps, iface)
  writeStr("ping_server_elf: entering server loop\n")

  # Server loop: poll the named channel for incoming messages
  while true:
    let n = nimixChanRecv(PingServerName, addr msgBuf[0], msgBuf.len)
    if n > 0:
      pingLogicHandleMsg(ps, addr msgBuf[0], n)
    # No sleep — cooperative; in SASOS this loop yields via scheduler tick
