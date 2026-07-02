# SPDX-License-Identifier: GPL-2.0
## Actor — a CPS continuation that consumes messages from a mailbox in a loop.
##
## Proven cps idiom (scratchpad POC7/POC10; mirrors nim-works/cps examples/
## iterator.nim). An actor body is `while true: receive(); handle(pending)`.
##
## Scheduler-gated: the scheduler pumps an actor ONLY when its inbox is
## non-empty, so `receive` always pops a real message (never an empty-inbox
## path — that path can't pause cleanly in cps and caused stale reprocessing).
##
## `receive` pops one message into `pending` and counts the entry. `pump` runs
## legs via `trampolineIt`, breaking when receive is entered for the SECOND time
## (i.e. one full receive+handler iteration has completed and the loop is about
## to block again). One message consumed and handled per pump.
##
## MUST compile --mm:arc --panics:on (nim-cps requirement).
import cps
import ../ipc/mailbox

const ActorInboxDepth* = 16

type
  ActorInbox* = ref object
    ## ref so actors share it without ptr/addr noise.
    mb*: Mailbox[ActorInboxDepth]

  Actor* = ref object of Continuation
    inbox*:   ActorInbox
    pending*: MailMsg      ## last message taken by receive
    entries*: int          ## receive entry count this pump (pump breaks at 2)

proc newInbox*(): ActorInbox =
  result = ActorInbox()
  mbInit(result.mb)

proc post*(inbox: ActorInbox; msg: MailMsg): bool =
  ## Deliver a message to an actor's inbox. False if full.
  mbPost(inbox.mb, msg)

proc inboxReady*(inbox: ActorInbox): bool =
  inbox != nil and not mbIsEmpty(inbox.mb)

proc self*(a: Actor): Actor {.cpsVoodoo.} =
  ## Read the running continuation inside a {.cps.} body (to reach `pending`).
  a

proc receive*(a: Actor): Actor {.cpsMagic.} =
  ## Enter a receive. First entry this pump: pop a message (scheduler guarantees
  ## non-empty) into `pending` and continue to the handler. Second entry: the
  ## previous message's handler has finished and we're about to block — signal
  ## the pump to stop by leaving `entries == 2`; return `a` so the continuation
  ## is preserved at exactly this receive for the next pump.
  inc a.entries
  if a.entries == 1:
    assert a.inbox != nil, "receive: actor has no inbox"
    let m = mbTryRecv(a.inbox.mb)
    assert m.hasValue, "receive: pumped with empty inbox"
    a.pending = m.value
  a

proc pump*(a: sink Actor): Actor =
  ## Consume and handle exactly one message. Resets the entry counter, then runs
  ## legs until receive is entered a second time (one full iteration done).
  a.entries = 0
  trampolineIt a:
    if (Actor it).entries >= 2:
      break
  result = a
