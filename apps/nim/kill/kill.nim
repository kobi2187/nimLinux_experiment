# NimixOS kill app — terminate a task by PID.
import nimix_common

proc nimixProcKillPid(pid: uint32): int {.importc, cdecl.}

proc appMain*() {.exportc.} =
  var argbuf: array[64, char]
  let n = nimixGetArgs(addr argbuf[0], argbuf.len)
  var pid: uint32 = 0
  var i = 0
  while i < n and argbuf[i] >= '0' and argbuf[i] <= '9':
    pid = pid * 10 + uint32(ord(argbuf[i]) - ord('0'))
    inc i
  if pid == 0:
    write("Usage: kill <pid>\n"); nimixExit(1)
  if nimixProcKillPid(pid) < 0:
    write("kill: no such process\n"); nimixExit(1)
  write("killed\n")
  nimixExit(0)
