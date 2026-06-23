# SPDX-License-Identifier: GPL-2.0
## ping_server — userspace ELF scaffold (ring-3 PIE)
##
## Uses the kernel ABI (patched in at load time) for all I/O and IPC.
## Same ping_logic as the kernel module — only the scaffold differs.
##
## Boot sequence:
##   1. Kernel loads this as PIE, patches ABI stubs, calls appMain()
##   2. appMain reads capability token from args (passed as uint64 string)
##   3. Server loop: nimixChanRecv("ping_server") → pingLogicHandleMsg
##   4. Reply uses nimixCapSend if token valid, nimixChanSend otherwise

import ping_logic

# ── Kernel ABI (all resolved by loader at runtime via stub patching) ──────────

proc nimixWrite(buf: pointer; len: int) {.importc, cdecl.}
proc nimixExit(code: int) {.importc, cdecl, noreturn.}
proc nimixGetArgs(buf: pointer; len: int): int {.importc, cdecl.}
proc nimixChanRecv(name: cstring; buf: pointer; bufLen: int): int {.importc, cdecl.}
proc nimixCapSend(name: cstring; tok: uint64; data: pointer; dataLen: int): int {.importc, cdecl.}
proc nimixChanSend(name: cstring; data: pointer; dataLen: int): int {.importc, cdecl.}
proc nimixEventPublish(topic: cstring; data: pointer; dataLen: int) {.importc, cdecl.}

# ── Helpers ───────────────────────────────────────────────────────────────────

proc writeStr(s: string) =
  if s.len > 0: nimixWrite(unsafeAddr s[0], s.len)

proc writeCStr(s: cstring) =
  var i = 0
  while s[i] != '\0': inc i
  if i > 0: nimixWrite(cast[pointer](s), i)

## Parse a decimal uint64 from a cstring; returns 0 on failure.
proc parseU64(p: cstring; n: int): uint64 =
  var v: uint64 = 0
  for i in 0 ..< n:
    let c = p[i]
    if c < '0' or c > '9': return 0
    v = v * 10 + uint64(ord(c) - ord('0'))
  v

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
var argsBuf: array[64, byte]
var capTok:  uint64 = 0

# ── Entry point ───────────────────────────────────────────────────────────────

proc appMain*() {.exportc.} =
  let iface = PingServerIface(
    log:     elfLog,
    publish: elfPublish,
    putChar: elfPutChar,
  )
  pingLogicInit(ps, iface)

  # Read capability token from kernel-supplied args (decimal uint64 string).
  let argsLen = nimixGetArgs(addr argsBuf[0], argsBuf.len)
  if argsLen > 0:
    capTok = parseU64(cast[cstring](addr argsBuf[0]), argsLen)

  if capTok != 0:
    writeStr("ping_server_elf: got capToken, using capSend\n")
  else:
    writeStr("ping_server_elf: no capToken, falling back to chanSend\n")

  writeStr("ping_server_elf: entering server loop\n")

  # Server loop: block on named channel, handle each message.
  while true:
    let n = nimixChanRecv(PingServerName, addr msgBuf[0], msgBuf.len)
    if n > 0:
      pingLogicHandleMsg(ps, addr msgBuf[0], n)

      # Reply: use capability-authenticated send when we hold a valid token.
      let reply: cstring = "pong!"
      if capTok != 0:
        discard nimixCapSend("pong", capTok, cast[pointer](reply), 5)
      else:
        discard nimixChanSend("pong", cast[pointer](reply), 5)
