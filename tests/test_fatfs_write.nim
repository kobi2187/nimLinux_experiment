# SPDX-License-Identifier: GPL-2.0
## Host-side unit tests for fatfs_write API.
## Tests Nim wrapper logic; no actual disk I/O.
##
## Compile with:
##   nim c -r --skipParentCfg --mm:refc --path:<repo-root> \
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

proc testDirListNotMounted() =
  fsMounted = false
  var buf: array[256, char]
  let r = fsDirList("/", addr buf[0], buf.len)
  assert r < 0, "fsDirList must return negative when not mounted"
  echo "PASS: fsDirList returns error when not mounted"

proc testFsConstants() =
  assert FA_READ  == 0x01'u8
  assert FA_WRITE == 0x02'u8
  assert AM_DIR   == 0x10'u8
  assert FR_OK    == 0.FRESULT
  echo "PASS: fs constants correct"

testWriteResultEnum()
testWriteFileMockMount()
testAppendFileMockMount()
testDeleteFileMockMount()
testMkdirMockMount()
testDirListNotMounted()
testFsConstants()
echo "All fatfs_write tests passed."
