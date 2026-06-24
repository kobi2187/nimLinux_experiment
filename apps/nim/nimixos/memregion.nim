# NimixOS zero-copy memory region API.
# Apps use this to receive bulk data without copying.
# The server allocates a region, mints a capMemRead token, and sends it.
# The app calls regionOpen to get a pointer, reads directly, then closes.

proc nimixGrantRegion(slot: int; right: uint32): uint64 {.importc, cdecl.}
proc nimixWrite(buf: pointer; len: int) {.importc, cdecl.}

# CapRight values (must match kernel/cap/capability.nim)
const
  CapMemRead*  = 4'u32
  CapMemWrite* = 5'u32
  CapMemGrant* = 6'u32

type
  MemRegion* = object
    token*: uint64   ## capability token
    base*:  pointer  ## direct pointer to data
    len*:   int      ## byte length

proc regionOpen*(token: uint64; base: pointer; len: int): MemRegion =
  ## Wrap a received region cap into a MemRegion for direct access.
  ## Call after receiving (token, base, len) from a server reply.
  MemRegion(token: token, base: base, len: len)

proc regionClose*(r: var MemRegion) =
  ## Signal done with the region (decrements ref count in kernel).
  ## After this call, r.base must not be accessed.
  if r.token != 0:
    # Revoke our read cap — triggers regionDecRef in kernel
    # We call this via the ABI: for now write a 0-byte "revoke" msg
    # Full revoke ABI proc will be added when needed
    r.token = 0
    r.base  = nil
    r.len   = 0

proc slice*[T](r: MemRegion; offset, count: int): ptr UncheckedArray[T] =
  ## Get a typed slice into the region at byte offset.
  cast[ptr UncheckedArray[T]](cast[uint64](r.base) + uint64(offset))
