# SPDX-License-Identifier: GPL-2.0
## Tests for SIP channel — kernel-mediated WASM→server IPC

import ../ipc/sip_chan
import ../ipc/server_chan

proc testSendToRegisteredServer() =
  # Set up a server channel and register it
  serverChanRegistryInit()
  var serverCh = serverChanCreate("echo")
  serverChanRegister(serverCh)

  # Send from "app" side
  let payload = "hello"
  let r = sipChanSend("echo", cast[ptr byte](unsafeAddr payload[0]), 5)
  assert r == sipOk, "send to registered server should succeed"

  # Server receives it
  let msg = serverChanRecv(serverCh)
  assert msg.hasValue, "server should receive the message"
  assert msg.value.len == 5, "payload length preserved"
  echo "PASS: send to registered server"

proc testSendToUnknownServer() =
  serverChanRegistryInit()
  let payload = "x"
  let r = sipChanSend("nonexistent", cast[ptr byte](unsafeAddr payload[0]), 1)
  assert r == sipNoServer, "unknown server returns sipNoServer"
  echo "PASS: unknown server error"

proc testSendEmptyPayload() =
  serverChanRegistryInit()
  var serverCh = serverChanCreate("empty_test")
  serverChanRegister(serverCh)
  let r = sipChanSend("empty_test", nil, 0)
  assert r == sipOk, "empty payload send should succeed"
  let msg = serverChanRecv(serverCh)
  assert msg.hasValue
  assert msg.value.len == 0
  echo "PASS: empty payload"

when isMainModule:
  testSendToRegisteredServer()
  testSendToUnknownServer()
  testSendEmptyPayload()
  echo "All SIP channel tests passed."
