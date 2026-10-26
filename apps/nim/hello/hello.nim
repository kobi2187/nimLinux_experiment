# NimixOS hello-world app — compiled with --os:standalone, PIE.
#
# Imports the 4-proc kernel ABI via importc. No stdlib I/O, no syscalls.
# The kernel's nimixAbi vtable handles everything at runtime.

proc nimixWrite(buf: pointer; len: int) {.importc, cdecl.}
proc nimixExit(code: int) {.importc, cdecl, noreturn.}

proc write(s: string) =
  if s.len > 0:
    nimixWrite(unsafeAddr s[0], s.len)

import nimix_entry

proc appMain() {.exportc.} =
  ## Entry point called by the kernel loader after relocating us.
  ## The kernel calls nimixAppMain() — not NimMain() — to avoid
  ## colliding with Nim's own generated NimMain symbol.
  nimixAppInit()   # module init first: --noMain skips it (nimix_entry)
  write("Hello from a NimixOS Nim app!\n")
  write("Running as PIE -- loader placed me anywhere it liked.\n")
  nimixExit(0)
