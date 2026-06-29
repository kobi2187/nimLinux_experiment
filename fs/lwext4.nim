# SPDX-License-Identifier: GPL-2.0
## lwext4 Mock/Stub Driver
## Registers prefix "/ext/" to VFS.

import ../core/log
import vfs

proc extMount(): bool {.nimcall.} =
  klog(llInfo, "lwext4: mounting stub volume")
  true

proc extReadInto(path: cstring; buf: ptr byte; len: int): int {.nimcall.} =
  klog(llInfo, "lwext4: read stub called for " & $path)
  if $path == "test.txt":
    let data = "Hello from lwext4!"
    if len < data.len: return -1
    let b = cast[ptr UncheckedArray[byte]](buf)
    for i in 0 ..< data.len:
      b[i] = byte(data[i])
    return data.len
  -1

proc extWriteFile(path: cstring; data: pointer; len: int): int {.nimcall.} =
  klog(llInfo, "lwext4: write stub called for " & $path)
  0

proc extDirList(path: cstring; buf: pointer; len: int): int {.nimcall.} =
  klog(llInfo, "lwext4: dir list stub called for " & $path)
  let entry = "test.txt\n"
  if len < entry.len: return -1
  let b = cast[ptr UncheckedArray[char]](buf)
  for i in 0 ..< entry.len:
    b[i] = entry[i]
  entry.len

proc registerLwExt4*() =
  registerDriver(FSDriver(
    name: "lwext4",
    prefix: "/ext/",
    mount: extMount,
    readInto: extReadInto,
    writeFile: extWriteFile,
    dirList: extDirList
  ))
