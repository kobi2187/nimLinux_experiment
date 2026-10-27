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

import buffers/types
export types

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
