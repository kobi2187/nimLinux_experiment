# SPDX-License-Identifier: GPL-2.0
## Virtual File System (VFS) Layer
## Routes path prefixes (/fat/, /lfs/, /ext/) to registered filesystem drivers.

import ../core/log
import ../core/serial

type
  FSDriver* = object
    name*: cstring
    prefix*: cstring
    mount*: proc(): bool {.nimcall.}
    readInto*: proc(path: cstring; buf: ptr byte; len: int): int {.nimcall.}
    writeFile*: proc(path: cstring; data: pointer; len: int): int {.nimcall.}
    dirList*: proc(path: cstring; buf: pointer; len: int): int {.nimcall.}

var gDrivers: array[8, FSDriver]
var gDriverCount = 0

proc registerDriver*(drv: FSDriver) =
  if gDriverCount < gDrivers.len:
    gDrivers[gDriverCount] = drv
    inc gDriverCount
    defaultSerial.putString("[INFO]  vfs: registered driver ")
    defaultSerial.putString(drv.name)
    defaultSerial.putString(" with prefix ")
    defaultSerial.putString(drv.prefix)
    defaultSerial.putChar('\n')
  else:
    klog(llError, "vfs: driver table full")

proc startsWith(s: cstring; prefix: cstring): bool =
  if s == nil or prefix == nil: return false
  var i = 0
  while prefix[i] != '\0':
    if s[i] == '\0': return false
    if s[i] != prefix[i]: return false
    inc i
  true

proc getDriver*(path: cstring; strippedPath: var cstring): ptr FSDriver =
  if path != nil:
    for i in 0 ..< gDriverCount:
      let drv = addr gDrivers[i]
      if drv.prefix != nil and startsWith(path, drv.prefix):
        # Strip prefix
        var offset = 0
        while drv.prefix[offset] != '\0': inc offset
        strippedPath = cast[cstring](cast[uint64](path) + uint64(offset))
        return drv
  # Default to the first driver (normally FatFs /)
  strippedPath = path
  if gDriverCount > 0:
    return addr gDrivers[0]
  nil

proc vfsMount*(): bool =
  defaultSerial.putString("vfsMount: gDriverCount = ")
  defaultSerial.putInt(gDriverCount)
  defaultSerial.putChar('\n')
  var ok = true
  for i in 0 ..< gDriverCount:
    defaultSerial.putString("vfsMount: driver ")
    defaultSerial.putInt(i)
    defaultSerial.putString(": name=")
    defaultSerial.putString(gDrivers[i].name)
    defaultSerial.putString(", mount=")
    defaultSerial.putHex(cast[uint64](gDrivers[i].mount))
    defaultSerial.putChar('\n')
    if gDrivers[i].mount != nil:
      defaultSerial.putString("vfsMount: invoking mount...\n")
      if not gDrivers[i].mount():
        ok = false
  ok

proc vfsReadInto*(path: cstring; buf: ptr byte; len: int): int =
  var stripped: cstring
  let drv = getDriver(path, stripped)
  if drv == nil or drv.readInto == nil: return -1
  drv.readInto(stripped, buf, len)

proc vfsWriteFile*(path: cstring; data: pointer; len: int): int =
  var stripped: cstring
  let drv = getDriver(path, stripped)
  if drv == nil or drv.writeFile == nil: return -1
  drv.writeFile(stripped, data, len)

proc vfsDirList*(path: cstring; buf: pointer; len: int): int =
  var stripped: cstring
  let drv = getDriver(path, stripped)
  if drv == nil or drv.dirList == nil: return -1
  drv.dirList(stripped, buf, len)
