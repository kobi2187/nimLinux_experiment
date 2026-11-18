# NimixOS clocktest — the fine clock from ring 3, without a syscall.
#   clocktest        sleep 300 PIT ticks (3 s) and measure it on the TSC clock;
#                    then time 100,000 clock reads. Needs 1 % accuracy.
#   clocktest write  write the time page: must fault and kill only this task.
import nimix_common
import nimix_entry
import nimix_time

proc nimixSleep(ticks: uint64) {.importc, cdecl.}

proc num(v: uint64): string =
  if v == 0: return "0"
  var x = v
  var d: array[20, char]
  var n = 0
  while x > 0:
    d[n] = char(ord('0') + int(x mod 10)); x = x div 10; inc n
  result = newString(n)
  for i in 0 ..< n: result[i] = d[n - 1 - i]

proc fail(msg: string) =
  write("clocktest: FAIL " & msg & "\n"); nimixExit(1)

proc modeMeasure() =
  if not fineClock(): fail("no fine clock published")
  let t0 = nanoTime()
  nimixSleep(300)                                  # 3 s of PIT ticks at 100 Hz
  let ms = (nanoTime() - t0) div 1_000_000
  # The wake lands on a tick edge, so 300 ticks is 299..301 periods: +-0.34 %.
  if ms < 2970 or ms > 3030: fail("3 s of ticks measured " & num(ms) & " ms")
  write("clocktest: 3000 ms of ticks measured " & num(ms) & " ms\n")
  const Reads = 100_000
  let a = nanoTime()
  var last = a
  for _ in 0 ..< Reads:
    let n = nanoTime()
    if n < last: fail("clock went backwards")
    last = n
  let per = (nanoTime() - a) div Reads
  write("clocktest: a clock read costs " & num(per) & " ns, no syscall\n")
  write("clocktest: ok\n")

proc modeWrite() =
  write("clocktest: writing the read-only time page\n")
  timePage().magic = 0                              # must fault: the page is user read-only
  write("clocktest: still alive?!\n")
  nimixExit(1)

proc appMain*() {.exportc.} =
  nimixAppInit()
  var a: array[16, char]
  let n = nimixGetArgs(addr a[0], a.len)
  var arg = ""
  for i in 0 ..< n:
    if a[i] == '\0': break
    arg.add a[i]
  if arg == "write": modeWrite() else: modeMeasure()
  nimixExit(0)
