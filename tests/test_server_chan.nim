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

proc testOwnedChannels() =
  serverChanRegistryInit()
  let ch = serverChanAllocOwned("dispatch", 0xABCD'u64)
  assert ch != nil, "owned channel created"
  assert serverChanFind("dispatch") == ch, "registered by name for senders"
  assert serverChanFindByCap(0xABCD'u64) == ch, "found by its receive cap"
  assert serverChanFindByCap(0x1234'u64) == nil, "wrong cap finds nothing"
  assert serverChanFindByCap(0) == nil, "null cap finds nothing"
  assert serverChanAllocOwned("dispatch", 0x9999'u64) == nil, "name squatting refused"
  assert serverChanAllocOwned("", 0x9999'u64) == nil, "empty name refused"
  for i in 1 ..< MaxOwnedChans:
    assert serverChanAllocOwned(cstring("s" & $i), uint64(100 + i)) != nil
  assert serverChanAllocOwned("overflow", 0x7777'u64) == nil, "pool exhaustion refused"
  echo "PASS: server-owned channels"

proc testReleaseFreesName() =
  serverChanRegistryInit()
  let ch = serverChanAllocOwned("fs", 5'u64)
  assert ch != nil
  serverChanRelease(ch)
  assert serverChanFind("fs") == nil, "released channel no longer found"
  assert serverChanFindByCap(5'u64) == nil
  assert serverChanAllocOwned("fs", 6'u64) != nil, "name free to re-create (server restart)"
  for i in 0 ..< MaxOwnedChans * 3:            # pool slots are reused too
    let c = serverChanAllocOwned(cstring("x" & $i), uint64(100 + i))
    assert c != nil, "pool slot reused after release"
    serverChanRelease(c)
  echo "PASS: release frees name and pool slot"

when isMainModule:
  testCreateAndName()
  testSendRecv()
  testEmptyRecv()
  testCapacity()
  testLookup()
  echo "All server channel tests passed."
  testOwnedChannels()
  testReleaseFreesName()
