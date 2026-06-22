# SPDX-License-Identifier: GPL-2.0
## Capability types for NimixOS — CapRight enum and CapToken opaque handle.

type
  CapRight* = enum
    capIpc    ## send/recv on named channels
    capFs     ## file system access
    capNet    ## network access
    capAdmin  ## kill other tasks, spawn servers

  CapToken* = distinct uint64
    ## Opaque capability token. High 32 bits = monotonic serial,
    ## low 32 bits = slot index. Never 0 (0 = invalid/null cap).

const NullCap* = CapToken(0)

proc `==`*(a, b: CapToken): bool {.borrow.}
proc isNull*(t: CapToken): bool = uint64(t) == 0
