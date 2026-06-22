# SPDX-License-Identifier: GPL-2.0
## ping_server — kernel module scaffold (monolithic / SASOS)
##
## Wraps ping_logic with kernel-side I/O: klog, eventPublish, defaultSerial.
## Runs in ring 0 as a cooperative task. No IPC overhead — direct calls.
## For the microkernel userspace version, see ping_server.nim (PIE ELF).

import ping_logic
import ../../ipc/server_chan
import ../../kernel/event_server
import ../../kernel/traits/event
import ../../core/log
import ../../core/serial

var
  pingChan*:   ServerChan   ## The server's named mailbox
  pingServer:  PingServer   ## Logic instance

# ── Kernel-side interface wiring ──────────────────────────────────────────────

proc kmodLog(msg: cstring) {.nimcall.} =
  klog(llInfo, msg)

proc kmodPublish(topic: cstring; data: pointer; dataLen: int) {.nimcall.} =
  eventPublish(topic, data, dataLen)

proc kmodPutChar(c: char) {.nimcall.} =
  defaultSerial.putChar(c)

let kmodIface = PingServerIface(
  log:     kmodLog,
  publish: kmodPublish,
  putChar: kmodPutChar,
)

# ── Public API (same names as old ping_server.nim) ────────────────────────────

proc pingServerInit*() =
  pingChan = serverChanCreate(PingServerName)
  serverChanRegister(pingChan)
  pingLogicInit(pingServer, kmodIface)

proc pingServerTick*() =
  ## Non-blocking: process one pending mailbox message if any.
  let msg = serverChanRecv(pingChan)
  if not msg.hasValue: return
  pingLogicHandleMsg(pingServer,
                     cast[ptr byte](unsafeAddr msg.value.data[0]),
                     int(msg.value.len))
