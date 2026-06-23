# SPDX-License-Identifier: GPL-2.0
# NimixOS file descriptor table shim.
# Maps fd 0/1/2 (stdin/stdout/stderr) to the serial ABI.
# This lets Nim's stdlib write/read procs work without a real OS.

when defined(testing):
  var testBuf*: seq[byte]
  proc nimixWrite(buf: pointer; len: int) =
    let p = cast[ptr UncheckedArray[byte]](buf)
    for i in 0 ..< len: testBuf.add(p[i])
else:
  proc nimixWrite(buf: pointer; len: int) {.importc, cdecl.}

type FdKind = enum fdSerial, fdNull

type FdEntry = object
  kind: FdKind
  open: bool

var fdTable: array[16, FdEntry]
var fdTableInited = false

proc fdTableInit*() =
  fdTable[0] = FdEntry(kind: fdSerial, open: true)  # stdin  (reads not impl yet)
  fdTable[1] = FdEntry(kind: fdSerial, open: true)  # stdout
  fdTable[2] = FdEntry(kind: fdSerial, open: true)  # stderr
  fdTableInited = true

proc fdWrite*(fd: int; buf: pointer; len: int): int =
  if not fdTableInited: fdTableInit()
  if fd < 0 or fd >= fdTable.len: return -1
  if not fdTable[fd].open: return -1
  case fdTable[fd].kind
  of fdSerial:
    nimixWrite(buf, len)
    return len
  of fdNull:
    return len

proc fdRead*(fd: int; buf: pointer; len: int): int =
  ## Stub — reads not yet implemented.
  -1

proc fdClose*(fd: int): int =
  if fd < 0 or fd >= fdTable.len: return -1
  fdTable[fd].open = false
  0
