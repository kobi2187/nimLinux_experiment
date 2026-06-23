# NimixOS top — system monitor. Loops: clear screen, print sysinfo, sleep 1s.
import nimix_common

proc nimixSysInfo(buf: pointer; len: int): int {.importc, cdecl.}
proc nimixSleep(ticks: uint64) {.importc, cdecl.}

proc appMain*() {.exportc.} =
  var buf: array[8192, char]
  # Loop 10 times then exit (no infinite loop — shell is synchronous)
  var i = 0
  while i < 10:
    # ANSI clear screen + home cursor
    var clear = "\x1b[2J\x1b[H"
    nimixWrite(addr clear[0], clear.len)
    write("=== NimixOS top ===\n")
    let n = nimixSysInfo(addr buf[0], buf.len)
    if n > 0: nimixWrite(addr buf[0], n)
    write("\n(press Ctrl+C to exit)\n")
    nimixSleep(100)  # 1 second at 100Hz
    inc i
  nimixExit(0)
