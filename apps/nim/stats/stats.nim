# NimixOS stats app — scheduler statistics and uptime.
import nimix_common

proc nimixSchedStats(buf: pointer; len: int): int {.importc, cdecl.}

proc appMain*() {.exportc.} =
  var buf: array[1024, char]
  let n = nimixSchedStats(addr buf[0], buf.len)
  if n > 0: nimixWrite(addr buf[0], n)
  nimixExit(0)
