# NimixOS ls app — list directory contents.
# Compiled with --os:standalone as a PIE ELF.

proc nimixWrite(buf: pointer; len: int) {.importc, cdecl.}
proc nimixExit(code: int) {.importc, cdecl, noreturn.}
proc nimixGetArgs(buf: pointer; len: int): int {.importc, cdecl.}
proc nimixFsReadDir(path: cstring; buf: pointer; len: int): int {.importc, cdecl.}

proc write(s: string) =
  if s.len > 0: nimixWrite(unsafeAddr s[0], s.len)

proc appMain*() {.exportc.} =
  # Get path from args, default to "/"
  var argbuf: array[256, char]
  let n = nimixGetArgs(addr argbuf[0], argbuf.len)
  let path: cstring = if n > 0: cast[cstring](addr argbuf[0]) else: "/"

  var buf: array[4096, char]
  let r = nimixFsReadDir(path, addr buf[0], buf.len)
  if r < 0:
    write("ls: not supported or path not found\n")
    nimixExit(1)
  if r > 0:
    nimixWrite(addr buf[0], r)
  nimixExit(0)
