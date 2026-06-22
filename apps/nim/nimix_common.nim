# NimixOS app common helpers — imported by all PIE ELF apps.
# Compiled with --os:standalone; no stdlib available.

proc nimixWrite*(buf: pointer; len: int) {.importc, cdecl.}
proc nimixExit*(code: int) {.importc, cdecl, noreturn.}
proc nimixGetArgs*(buf: pointer; len: int): int {.importc, cdecl.}

proc write*(s: string) {.inline.} =
  if s.len > 0: nimixWrite(unsafeAddr s[0], s.len)
