# SPDX-License-Identifier: GPL-2.0
## Tests for fd_table shim (host-side, no hardware needed)

import ../kernel/abi/fd_table

proc testFdTableInit() =
  fdTableInit()
  # After init, fd 0/1/2 should be writable (fdWrite returns len, not -1)
  var buf: array[4, byte] = [1'u8, 2, 3, 4]
  let r = fdWrite(1, addr buf[0], 4)
  assert r == 4, "fdWrite to stdout should return len"
  echo "PASS: fdTableInit sets fd 0/1/2 as open"

proc testFdWriteCaptures() =
  testBuf.setLen(0)
  var msg = "hi"
  let r = fdWrite(1, cstring(msg), 2)
  assert r == 2, "fdWrite should return 2"
  assert testBuf.len == 2, "testBuf should have 2 bytes"
  assert testBuf[0] == ord('h').byte
  assert testBuf[1] == ord('i').byte
  echo "PASS: fdWrite to fd 1 routes bytes to nimixWrite"

proc testFdWriteInvalidFd() =
  let r = fdWrite(-1, nil, 0)
  assert r == -1, "fdWrite to -1 should return -1"
  let r2 = fdWrite(100, nil, 0)
  assert r2 == -1, "fdWrite to out-of-range fd should return -1"
  echo "PASS: fdWrite to invalid fd returns -1"

proc testFdClosePreventWrite() =
  fdTableInit()
  let closed = fdClose(1)
  assert closed == 0, "fdClose should return 0"
  var buf: array[1, byte]
  let r = fdWrite(1, addr buf[0], 1)
  assert r == -1, "fdWrite after fdClose should return -1"
  # re-open for any subsequent tests
  fdTableInit()
  echo "PASS: fdClose then fdWrite returns -1"

when isMainModule:
  testFdTableInit()
  testFdWriteCaptures()
  testFdWriteInvalidFd()
  testFdClosePreventWrite()
  echo "All fd_table tests passed."
