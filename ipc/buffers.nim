# SPDX-License-Identifier: GPL-2.0
## Buffers — the FROZEN bulk-data API (2026-10-27).
##
## Spec: docs/proposals/bulk_data.md (v2, frozen). Implementation:
## subprojects/buffers. This module is the ONLY thing that crosses that
## boundary; changing it is cross-cutting in both projects (dialogue + both
## DECISIONS.md files).
##
## The rule: mutable memory is never shared. A buffer is owned (exactly one
## task may access it) or sealed (immutable, any holder may read); ownership
## changes only by move or lend. Rings are the only concurrent sharing and
## carry descriptors or ≤ InlineMax inline bytes — never bulk data.
##
## STUB: every operation returns beNotImplemented until the sub-project
## delivers, so nothing can come to depend on unenforced semantics.

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

# ── buffers ──────────────────────────────────────────────────────────────────

proc bufCreate*(size: int; h: var BufHandle): BufError =
  ## New owned buffer charged to the caller's memory budget.
  beNotImplemented
proc bufMap*(h: BufHandle; p: var pointer): BufError =
  ## Access in the caller's view with the handle's rights.
  beNotImplemented
proc bufUnmap*(h: BufHandle): BufError = beNotImplemented
proc bufSize*(h: BufHandle; size: var int): BufError = beNotImplemented
proc bufState*(h: BufHandle; s: var BufState): BufError = beNotImplemented
proc bufSeal*(h: BufHandle): BufError =
  ## owned → sealed (read-only for every holder, forever).
  beNotImplemented
proc bufReturn*(h: BufHandle): BufError =
  ## Borrower ends a lend early (otherwise automatic on reply).
  beNotImplemented
proc bufClose*(h: BufHandle): BufError =
  ## Drop the handle; memory is reclaimed at the last reference.
  beNotImplemented

# ── messages with handles (control plane: dispatcher forwards in tmTransit) ──

proc msgSend*(chanCap: uint64; data: pointer; len: int;
              handles: openArray[MsgHandle]): BufError =
  ## Send a control message; the kernel moves each handle into the
  ## receiver's table per its mode. ≤ MaxMsgHandles handles.
  beNotImplemented
proc msgRecv*(recvCap: uint64; data: pointer; cap: int; len: var int;
              handles: var array[MaxMsgHandles, BufHandle]; n: var int): BufError =
  beNotImplemented

proc bufRefCheck*(r: BufRef; handles: openArray[BufHandle]): BufError =
  ## Receiver-side validation: handle present, offset + len within the buffer.
  beNotImplemented

# ── session rings (data plane for streams) ───────────────────────────────────

proc ringCreate*(slots: int; producer, consumer: var RingEnd): BufError =
  ## slots: power of two. Ends are transferable like any handle.
  beNotImplemented
proc ringPush*(p: RingEnd; slot: RingSlot): BufError =
  ## Library-only, no kernel call: stage one slot in the ring.
  beNotImplemented
proc ringSubmit*(p: RingEnd): BufError =
  ## ONE kernel call per batch: validates every staged BufRef, flips its
  ## ownership to the consumer, posts one mailbox wake to the consumer actor.
  beNotImplemented
proc ringPop*(c: RingEnd; slot: var RingSlot): BufError = beNotImplemented

# ── budgets (no ambient authority) ───────────────────────────────────────────

proc budgetAvailable*(bytes: var int): BufError =
  ## Remaining memory budget of the caller (charges follow ownership).
  beNotImplemented

proc installEnforcer*(e: BufEnforcer) =
  ## Each kernel model installs its enforcement hook at boot.
  discard
