# SPDX-License-Identifier: GPL-2.0
## ping_server — pure logic library
##
## Zero kernel/userspace assumptions. All I/O injected via PingServerIface.
## Compile this into a kernel module, a PIE server, or a test harness — same code.

const PingServerName* = "ping_server"

type
  PingServerIface* = object
    ## Dependencies injected by the scaffold. No defaults — caller must fill all.
    log*:     proc(msg: cstring) {.nimcall.}
      ## Emit a diagnostic line (goes to serial/VGA in kernel, stdout in tests).
    publish*: proc(topic: cstring; data: pointer; dataLen: int) {.nimcall.}
      ## Publish an event to any subscribers on `topic`.
    putChar*: proc(c: char) {.nimcall.}
      ## Write a single character to the server's output stream.

  PingServer* = object
    ## All mutable state for one ping server instance.
    iface*: PingServerIface

proc pingLogicInit*(ps: var PingServer; iface: PingServerIface) =
  ## Initialise with injected interface. Call once before any tick.
  ps.iface = iface
  ps.iface.log("ping_server: ready")
  ps.iface.publish("server.ready", PingServerName.cstring, PingServerName.len)

proc pingLogicHandleMsg*(ps: var PingServer; data: ptr byte; dataLen: int) =
  ## Process one received message — log it, publish pong reply.
  ## Called by the scaffold whenever a message arrives.
  ps.iface.log("ping_server: got message")
  ps.iface.putChar('[')
  for i in 0 ..< dataLen:
    ps.iface.putChar(cast[ptr UncheckedArray[byte]](data)[i].char)
  ps.iface.putChar(']')
  ps.iface.putChar('\n')

  let reply: cstring = "pong!"
  ps.iface.publish("pong", cast[pointer](reply), 5)
  ps.iface.log("ping_server: sent pong")
