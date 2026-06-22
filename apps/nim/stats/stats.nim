# NimixOS stats app — scheduler statistics and uptime.
# Compiled with --os:standalone as a PIE ELF.

proc nimixWrite(buf: pointer; len: int) {.importc, cdecl.}
proc nimixExit(code: int) {.importc, cdecl, noreturn.}
proc nimixSchedStats(buf: pointer; len: int): int {.importc, cdecl.}

proc write(s: string) =
  if s.len > 0: nimixWrite(unsafeAddr s[0], s.len)

proc appMain*() {.exportc.} =
  var buf: array[1024, char]
  let n = nimixSchedStats(addr buf[0], buf.len)
  if n > 0:
    nimixWrite(addr buf[0], n)
  nimixExit(0)
