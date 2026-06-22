# Required by --os:standalone. Routes Nim panics to the kernel ABI exit.
proc nimixExit(code: int) {.importc, cdecl, noreturn.}

proc rawoutput(s: string) =
  proc nimixWrite(buf: pointer; len: int) {.importc, cdecl.}
  if s.len > 0:
    nimixWrite(unsafeAddr s[0], s.len)

proc panic(s: string) {.noreturn.} =
  rawoutput("PANIC: ")
  rawoutput(s)
  nimixExit(1)
