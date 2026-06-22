# NimixOS ps app — list all tasks.
import nimix_common

proc nimixProcList(buf: pointer; len: int): int {.importc, cdecl.}

proc appMain*() {.exportc.} =
  var buf: array[4096, char]
  write("PID CLASS STATE    NAME\n")
  write("--- ----- -------- ----------------\n")
  let n = nimixProcList(addr buf[0], buf.len)
  if n > 0: nimixWrite(addr buf[0], n)
  nimixExit(0)
