# NimixOS kill app — terminate a task by PID.
# Compiled with --os:standalone as a PIE ELF.

proc nimixWrite(buf: pointer; len: int) {.importc, cdecl.}
proc nimixExit(code: int) {.importc, cdecl, noreturn.}
proc nimixGetArgs(buf: pointer; len: int): int {.importc, cdecl.}
proc nimixProcKillPid(pid: uint32): int {.importc, cdecl.}

proc write(s: string) =
  if s.len > 0: nimixWrite(unsafeAddr s[0], s.len)

proc appMain*() {.exportc.} =
  var argbuf: array[64, char]
  let n = nimixGetArgs(addr argbuf[0], argbuf.len)
  # Parse uint32 from argbuf
  var pid: uint32 = 0
  var i = 0
  while i < n and argbuf[i] >= '0' and argbuf[i] <= '9':
    pid = pid * 10 + uint32(ord(argbuf[i]) - ord('0'))
    inc i
  if pid == 0:
    write("Usage: kill <pid>\n")
    nimixExit(1)
  let r = nimixProcKillPid(pid)
  if r < 0:
    write("kill: no such process\n")
    nimixExit(1)
  write("killed\n")
  nimixExit(0)
