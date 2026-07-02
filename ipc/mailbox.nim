# SPDX-License-Identifier: GPL-2.0
## Mailbox — bounded MPSC ring of fixed-size messages.
##
## The one queue primitive for NimixOS actors. Lock-free for single-CPU use
## (SMP will guard head/tail with a spinlock — deferred). Kernel-safe: no
## stdlib, no heap; --os:any compatible. Payload bytes are copied in/out.

const MailMsgMax* = 256   ## max payload bytes per message

type
  MailMsg* = object
    len*:  uint16
    data*: array[MailMsgMax, byte]

  MaybeMail* = object
    hasValue*: bool
    value*:    MailMsg

  Mailbox*[N: static int] = object
    buf:   array[N, MailMsg]
    head:  int
    tail:  int
    count: int

proc mbInit*[N](mb: var Mailbox[N]) =
  mb.head = 0; mb.tail = 0; mb.count = 0

proc mbCount*[N](mb: Mailbox[N]): int = mb.count
proc mbIsEmpty*[N](mb: Mailbox[N]): bool = mb.count == 0

proc mbPost*[N](mb: var Mailbox[N]; msg: MailMsg): bool =
  ## Enqueue. False when full (caller applies backpressure).
  if mb.count >= N: return false
  mb.buf[mb.tail] = msg
  mb.tail = (mb.tail + 1) mod N
  inc mb.count
  assert mb.count <= N, "mailbox count exceeded capacity"
  true

proc mbTryRecv*[N](mb: var Mailbox[N]): MaybeMail =
  ## Dequeue oldest. hasValue=false when empty.
  if mb.count == 0:
    result.hasValue = false
    return
  result.value    = mb.buf[mb.head]
  result.hasValue = true
  mb.head = (mb.head + 1) mod N
  dec mb.count
  assert mb.count >= 0, "mailbox count underflow"
