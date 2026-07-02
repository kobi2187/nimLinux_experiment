# SPDX-License-Identifier: GPL-2.0
## Host test for the Mailbox MPSC ring primitive.
import ipc/mailbox
import unittest

proc mkMsg(b: byte): MailMsg =
  result.len = 1
  result.data[0] = b

suite "Mailbox ring":
  test "post then recv is FIFO":
    var mb: Mailbox[4]
    mbInit(mb)
    check mbPost(mb, mkMsg(1))
    check mbPost(mb, mkMsg(2))
    check mbCount(mb) == 2
    let a = mbTryRecv(mb)
    check a.hasValue and a.value.data[0] == 1
    let b = mbTryRecv(mb)
    check b.hasValue and b.value.data[0] == 2
    check mbIsEmpty(mb)

  test "recv on empty returns hasValue=false":
    var mb: Mailbox[2]
    mbInit(mb)
    check not mbTryRecv(mb).hasValue

  test "post on full returns false, no overwrite":
    var mb: Mailbox[2]
    mbInit(mb)
    check mbPost(mb, mkMsg(10))
    check mbPost(mb, mkMsg(20))
    check not mbPost(mb, mkMsg(30))     # full
    check mbTryRecv(mb).value.data[0] == 10   # oldest intact

  test "wraparound preserves order":
    var mb: Mailbox[2]
    mbInit(mb)
    discard mbPost(mb, mkMsg(1))
    discard mbTryRecv(mb)               # head advances past 0
    discard mbPost(mb, mkMsg(2))
    discard mbPost(mb, mkMsg(3))        # tail wraps
    check mbTryRecv(mb).value.data[0] == 2
    check mbTryRecv(mb).value.data[0] == 3

import ipc/mailbox_registry

# Concrete thunks binding a Mailbox[4] into the untyped registry.
proc post4(mb: pointer; msg: MailMsg): bool {.nimcall.} =
  mbPost(cast[ptr Mailbox[4]](mb)[], msg)
proc recv4(mb: pointer): MaybeMail {.nimcall.} =
  mbTryRecv(cast[ptr Mailbox[4]](mb)[])

suite "Mailbox registry":
  test "register, find, post-by-name":
    mbRegistryInit()
    var inbox: Mailbox[4]
    mbInit(inbox)
    mbRegister("audio", addr inbox, post4, recv4)
    check mbFind("audio") != nil
    check mbFind("missing") == nil
    check mbPostByName("audio", mkMsg(7))
    check mbTryRecv(inbox).value.data[0] == 7

  test "post to unknown name returns false":
    mbRegistryInit()
    check not mbPostByName("nope", mkMsg(1))

echo "=== All mailbox tests passed ==="
