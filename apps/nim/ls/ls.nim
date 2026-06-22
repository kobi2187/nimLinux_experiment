# NimixOS ls app — list directory contents.
import nimix_common

proc nimixFsReadDir(path: cstring; buf: pointer; len: int): int {.importc, cdecl.}

proc appMain*() {.exportc.} =
  var argbuf: array[256, char]
  let n = nimixGetArgs(addr argbuf[0], argbuf.len)
  let path: cstring = if n > 0: cast[cstring](addr argbuf[0]) else: "/"
  var buf: array[4096, char]
  let r = nimixFsReadDir(path, addr buf[0], buf.len)
  if r < 0: write("ls: not supported or path not found\n"); nimixExit(1)
  if r > 0: nimixWrite(addr buf[0], r)
  nimixExit(0)
