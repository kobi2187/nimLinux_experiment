# NimixOS stats app — scheduler statistics and uptime.
import nimix_common
import nimix_entry

proc nimixSchedStats(buf: pointer; len: int): int {.importc, cdecl.}

proc appMain*() {.exportc.} =
  nimixAppInit()   # module init first: --noMain skips it (nimix_entry)
  var buf: array[1024, char]
  let n = nimixSchedStats(addr buf[0], buf.len)
  if n > 0: nimixWrite(addr buf[0], n)
  nimixExit(0)
