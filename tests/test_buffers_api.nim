# SPDX-License-Identifier: GPL-2.0
## Freezes the buffers API's wire layouts (ipc/buffers.nim, 2026-10-27):
## these sizes cross task boundaries in messages and rings, so a change here
## is a protocol change — cross-cutting in the parent and subprojects/buffers.

import std/unittest
import ../ipc/buffers
import ../ipc/mailbox

suite "buffers API (frozen layouts)":
  test "BufRef is 12 bytes, packed":
    check sizeof(BufRef) == 12
    check offsetOf(BufRef, offset) == 4 and offsetOf(BufRef, len) == 8

  test "a ring slot is 256 bytes and fits an inline payload or a BufRef":
    check sizeof(RingSlot) == RingSlotSize
    check RingSlotSize - 16 >= InlineMax
    check RingSlotSize - 16 >= sizeof(BufRef)
    check RingSlotSize == MailMsgMax                 # same size as an actor message

  test "Stage A geometry":
    check ArenaSize mod BlockSize == 0
    check ArenaSize div BlockSize == 64

  test "the stub refuses everything (no unenforced semantics)":
    var h: BufHandle
    check bufCreate(4096, h) == beNotImplemented
    check h == NoHandle
    var p, c: RingEnd
    check ringCreate(8, p, c) == beNotImplemented
