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

const
  MaxCaps* = 64

type
  CapEntry* = object
    token*:  CapToken
    pid*:    uint32      ## owning task PID (0 = unowned)
    right*:  CapRight
    valid*:  bool

  CapTable* = object
    entries*: array[MaxCaps, CapEntry]
    nextSerial: uint32   ## monotonic counter for token minting

var gCapTable*: CapTable

proc capTableInit*() =
  gCapTable.nextSerial = 1
  for i in 0 ..< MaxCaps:
    gCapTable.entries[i] = CapEntry(valid: false, token: NullCap, pid: 0)

proc makeToken*(serial: uint32; slot: int): CapToken =
  CapToken((uint64(serial) shl 32) or uint64(slot))

proc tokenSlot*(t: CapToken): int = int(uint64(t) and 0xFFFFFFFF'u64)
proc tokenSerial*(t: CapToken): uint32 = uint32(uint64(t) shr 32)
