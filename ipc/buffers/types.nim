# SPDX-License-Identifier: GPL-2.0
## Frozen types of the buffers API (2026-10-27) — re-exported by
## ipc/buffers.nim, which is the only boundary. Split out so the
## implementation modules (ipc/buffers/*) can share them without a cycle.

const
  InlineMax*  = 240                 ## inline lane: copied, no handle
  BlockSize*  = 2 * 1024 * 1024     ## Stage A ownership/enforcement granule
  ArenaSize*  = 128 * 1024 * 1024   ## Stage A buffer arena (tunable)
  MaxMsgHandles* = 4                ## handles carried out-of-band per message
  RingSlotSize*  = 256              ## one cache-friendly slot = MailMsg size

type
  BufHandle* = distinct uint32
    ## Index into the calling task's handle table; 0 = none. Never a global
    ## number: authority comes only from creation or receipt in a message.

  BufRight* = enum
    brRead, brWrite, brMap, brTransfer
  BufRights* = set[BufRight]

  BufState* = enum
    bsOwned      ## exactly one task may access it
    bsLent       ## temporarily held by a borrower; returns on reply/bufReturn
    bsSealed     ## immutable forever; any holder may read

  TransferMode* = enum
    tmMove       ## sender loses the buffer; its budget charge moves too
    tmLend       ## receiver holds it until reply/bufReturn; sender has no access meanwhile
    tmShare      ## sealed buffers only: receiver gets read access
    tmTransit    ## forwarder (dispatcher): may pass it on, may never map it

  BufError* = enum
    beOk, beNotImplemented, beNoBudget, beBadHandle, beNoRight, beNotOwned,
    beSealed, beBounds, beRingFull, beRingEmpty, beTooManyHandles

  BufRef* {.packed.} = object
    ## Descriptor in a message body or ring slot: refers to handles[handleIdx]
    ## of the carrying message (or the ring's attached set). The receiver
    ## validates it (bufRefCheck) before any access.
    handleIdx*: uint16
    flags*:     uint16
    offset*:    uint32
    len*:       uint32

  MsgHandle* = object
    handle*: BufHandle
    mode*:   TransferMode

  RingSlotKind* = enum
    rsInline, rsRef

  RingSlot* {.packed.} = object
    ## Lane 1 (inline, ≤ InlineMax) or lane 2 (one BufRef).
    kind*:   uint8               ## RingSlotKind
    pad*:    uint8
    len*:    uint16              ## inline byte count
    tag*:    uint32              ## protocol-defined (opcode / event kind)
    seq*:    uint64              ## producer sequence (orders batches)
    data*:   array[RingSlotSize - 16, byte]   ## inline bytes or a BufRef

  RingEnd* = distinct uint32     ## a producer or consumer end (a handle)

  BufEnforcer* = object
    ## Per-kernel-model enforcement hook (the oskit seam): the shared state
    ## machine calls these; SASOS installs no-ops (the type system enforces),
    ## monolithic updates its ownership table, microkernel flips page rights.
    onGrant*:  proc(pid: uint32; blockIdx: int; rights: BufRights) {.nimcall.}
    onRevoke*: proc(pid: uint32; blockIdx: int) {.nimcall.}

proc `==`*(a, b: BufHandle): bool {.borrow.}
proc `==`*(a, b: RingEnd): bool {.borrow.}
const NoHandle* = BufHandle(0)

