# SPDX-License-Identifier: GPL-2.0
## littlefs Mock/Stub Driver
## Registers prefix "/lfs/" to VFS.

import ../core/log
import vfs

proc lfsMount(): bool {.nimcall.} =
  klog(llInfo, "littlefs: mounting stub volume")
  true

proc lfsReadInto(path: cstring; buf: ptr byte; len: int): int {.nimcall.} =
  klog(llInfo, "littlefs: read stub called for " & $path)
  if $path == "test.txt":
    let data = "Hello from LittleFS!"
    if len < data.len: return -1
    let b = cast[ptr UncheckedArray[byte]](buf)
    for i in 0 ..< data.len:
      b[i] = byte(data[i])
    return data.len
  -1

proc lfsWriteFile(path: cstring; data: pointer; len: int): int {.nimcall.} =
  klog(llInfo, "littlefs: write stub called for " & $path)
  0

proc lfsDirList(path: cstring; buf: pointer; len: int): int {.nimcall.} =
  klog(llInfo, "littlefs: dir list stub called for " & $path)
  let entry = "test.txt\n"
  if len < entry.len: return -1
  let b = cast[ptr UncheckedArray[char]](buf)
  for i in 0 ..< entry.len:
    b[i] = entry[i]
  entry.len

proc registerLittleFS*() =
  registerDriver(FSDriver(
    name: "littlefs",
    prefix: "/lfs/",
    mount: lfsMount,
    readInto: lfsReadInto,
    writeFile: lfsWriteFile,
    dirList: lfsDirList
  ))
