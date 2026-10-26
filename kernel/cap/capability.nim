# SPDX-License-Identifier: GPL-2.0
## Capability types for NimixOS — CapRight enum and CapToken opaque handle.

import ../../mm/region_allocator

type
  CapRight* = enum
    capIpc    ## send/recv on named channels
    capFs     ## file system access
    capNet    ## network access
    capAdmin  ## kill other tasks, spawn servers
    capMemRead   ## read-only view of a specific region slot
    capMemWrite  ## read-write ownership of a region slot
    capMemGrant  ## can mint child caps from this region (parent only)

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
    token*:      CapToken
    pid*:        uint32      ## owning task PID (0 = unowned)
    right*:      CapRight
    valid*:      bool
    regionSlot*: int         ## -1 = not a region cap; >= 0 = region slot index

  CapTable* = object
    entries*: array[MaxCaps, CapEntry]
    nextSerial: uint32   ## monotonic counter for token minting

var gCapTable*: CapTable

proc capTableInit*() =
  gCapTable.nextSerial = 1
  for i in 0 ..< MaxCaps:
    gCapTable.entries[i] = CapEntry(valid: false, token: NullCap, pid: 0, regionSlot: -1)

proc makeToken*(serial: uint32; slot: int): CapToken =
  CapToken((uint64(serial) shl 32) or uint64(slot))

proc tokenSlot*(t: CapToken): int = int(uint64(t) and 0xFFFFFFFF'u64)
proc tokenSerial*(t: CapToken): uint32 = uint32(uint64(t) shr 32)

proc capGrant*(pid: uint32; right: CapRight): CapToken =
  ## Mint a new capability token for `pid` with `right`.
  ## Returns NullCap if table is full.
  ## Serial 0 is never minted: makeToken(0, slot 0) == NullCap. Checked before
  ## minting so a zero-initialised table (capTableInit never called) is valid.
  for i in 0 ..< MaxCaps:
    if not gCapTable.entries[i].valid:
      if gCapTable.nextSerial == 0: gCapTable.nextSerial = 1
      let tok = makeToken(gCapTable.nextSerial, i)
      inc gCapTable.nextSerial
      gCapTable.entries[i] = CapEntry(token: tok, pid: pid, right: right, valid: true, regionSlot: -1)
      return tok
  NullCap

proc capRevoke*(tok: CapToken) =
  ## Invalidate a capability token.
  if tok.isNull: return
  let slot = tokenSlot(tok)
  if slot < 0 or slot >= MaxCaps: return
  if gCapTable.entries[slot].token == tok:
    # If this was a region cap, decrement region ref count
    let rs = gCapTable.entries[slot].regionSlot
    if rs >= 0:
      discard regionDecRef(RegionHandle(rs))
      gCapTable.entries[slot].regionSlot = -1
    gCapTable.entries[slot].valid = false

proc capGrantRegion*(slot: int; pid: uint32; right: CapRight): CapToken =
  ## Mint a memory capability for `pid` on region `slot` with `right`.
  ## Also increments the region's ref count.
  ## Returns NullCap if slot invalid or cap table full.
  if slot < 0 or slot >= MaxRegions: return NullCap
  let h = RegionHandle(slot)
  if not regionValid(h): return NullCap
  let tok = capGrant(pid, right)
  if tok.isNull: return NullCap
  gCapTable.entries[tokenSlot(tok)].regionSlot = slot
  regionAddRef(h)
  tok

proc capOwner*(tok: CapToken): uint32 =
  ## PID the (valid) token was granted to; 0 if invalid or revoked.
  if tok.isNull: return 0
  let slot = tokenSlot(tok)
  if slot < 0 or slot >= MaxCaps: return 0
  let e = gCapTable.entries[slot]
  if e.valid and e.token == tok: e.pid else: 0

proc capCheck*(tok: CapToken; right: CapRight): bool =
  ## Returns true iff tok is valid, not revoked, and grants `right`.
  if tok.isNull: return false
  let slot = tokenSlot(tok)
  if slot < 0 or slot >= MaxCaps: return false
  let e = gCapTable.entries[slot]
  e.valid and e.token == tok and e.right == right
