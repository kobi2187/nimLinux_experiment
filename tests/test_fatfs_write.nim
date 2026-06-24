# SPDX-License-Identifier: GPL-2.0
## Host-side unit tests for fatfs_write API.
## Tests Nim wrapper logic; no actual disk I/O.
##
## Compile with:
##   nim c -r --skipParentCfg --mm:refc --path:/home/kl/prog/nimLinux_experiment \
##     -d:noSignalHandler -d:noKernelHardware tests/test_fatfs_write.nim

import ../fs/fatfs        # fsMounted
import ../fs/fatfs_write

proc testWriteResultEnum() =
  assert wOk != wWriteError
  assert wMountError != wOk
  assert wOpenError != wOk
  assert wPartialWrite != wWriteError
  assert wDeleteError != wMkdirError
  echo "PASS: WriteResult enum values distinct"

proc testWriteFileMockMount() =
  fsMounted = false
  let r = fsWriteFile("/test.txt", nil, 0)
  assert r == wMountError, "expected wMountError when not mounted, got: " & $r
  echo "PASS: fsWriteFile returns wMountError when not mounted"

proc testAppendFileMockMount() =
  fsMounted = false
  let r = fsAppendFile("/test.txt", nil, 0)
  assert r == wMountError, "expected wMountError when not mounted, got: " & $r
  echo "PASS: fsAppendFile returns wMountError when not mounted"

proc testDeleteFileMockMount() =
  fsMounted = false
  let r = fsDeleteFile("/test.txt")
  assert r == wMountError or r == wDeleteError
  echo "PASS: fsDeleteFile returns error when not mounted"

proc testMkdirMockMount() =
  fsMounted = false
  let r = fsMkdir("/newdir")
  assert r == wMountError or r == wMkdirError
  echo "PASS: fsMkdir returns error when not mounted"

testWriteResultEnum()
testWriteFileMockMount()
testAppendFileMockMount()
testDeleteFileMockMount()
testMkdirMockMount()
echo "All fatfs_write tests passed."
