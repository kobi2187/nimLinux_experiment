# NimixOS fault app — crash on purpose in ring 3 (crash-handling test tool).
#   fault        write through a null pointer   (#PF)
#   fault ud     execute ud2                     (#UD)
# The kernel must kill only this task: crash report on serial, resources
# released, shell and other tasks keep running.
import nimix_common
import nimix_entry

proc nullWrite() {.noinline.} =
  write("fault: writing through a null pointer\n")
  cast[ptr int](0)[] = 42

proc invalidOpcode() {.noinline.} =
  write("fault: executing ud2\n")
  {.emit: "__asm__ volatile(\"ud2\");".}

proc appMain*() {.exportc.} =
  nimixAppInit()   # module init first: --noMain skips it (nimix_entry)
  var argbuf: array[16, char]
  let n = nimixGetArgs(addr argbuf[0], argbuf.len)
  if n >= 2 and argbuf[0] == 'u' and argbuf[1] == 'd': invalidOpcode()
  else: nullWrite()
  write("fault: still alive?!\n")
  nimixExit(1)
