# SPDX-License-Identifier: GPL-2.0
## Tests for server channel — named MPSC mailbox, no hardware

import ../ipc/server_chan

proc testCreateAndName() =
  var ch = serverChanCreate("ping")
  assert serverChanName(ch) == "ping", "name should be 'ping'"
  echo "PASS: channel creation and name"

proc testSendRecv() =
  var ch = serverChanCreate("test")
  var msg: ServerMsg
  msg.len = 4
  msg.data[0] = byte('p'); msg.data[1] = byte('i')
  msg.data[2] = byte('n'); msg.data[3] = byte('g')

  assert serverChanPost(ch, msg), "post should succeed"
  let r = serverChanRecv(ch)
  assert r.hasValue, "recv should return a message"
  assert r.value.len == 4, "message length preserved"
  assert r.value.data[0] == byte('p'), "data[0] = 'p'"
  echo "PASS: send and receive"

proc testEmptyRecv() =
  var ch = serverChanCreate("empty")
  let r = serverChanRecv(ch)
  assert not r.hasValue, "empty channel returns none"
  echo "PASS: empty channel recv"

proc testCapacity() =
  var ch = serverChanCreate("cap")
  var msg: ServerMsg
  msg.len = 1; msg.data[0] = byte('x')
  # Fill to capacity (ServerChanDepth = 16)
  for i in 0..<16:
    assert serverChanPost(ch, msg), "post within capacity"
  # One more should fail (buffer full)
  assert not serverChanPost(ch, msg), "post beyond capacity returns false"
  echo "PASS: capacity limit"

proc testLookup() =
  serverChanRegistryInit()
  var ch = serverChanCreate("lookup_test")
  serverChanRegister(ch)
  let found = serverChanFind("lookup_test")
  assert found != nil, "registered channel should be findable"
  assert serverChanName(found[]) == "lookup_test"
  echo "PASS: channel registry lookup"

when isMainModule:
  testCreateAndName()
  testSendRecv()
  testEmptyRecv()
  testCapacity()
  testLookup()
  echo "All server channel tests passed."
