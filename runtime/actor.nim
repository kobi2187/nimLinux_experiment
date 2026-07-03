# SPDX-License-Identifier: GPL-2.0
## Actor — a CPS continuation that receives messages via idiomatic cps suspend.
##
## Pattern from nim-works/cps examples/coroutine.nim (the intended idiom):
##   - `suspend()` is a dumb park: it stores the continuation in `suspended` and
##     reads nothing. That is the ONLY thing the magic does.
##   - the SENDER plants the message into `pending`, THEN calls `resume`.
##   - the body reads the message with `recv()` AFTER suspend returns — so it is
##     always fresh. No flags, no counters, no empty-inbox path.
##
## A server actor body is:  while true: suspend(); handle(recv())
##
## This avoids every hazard of the earlier looping-with-internal-pop model (stale
## re-processing, one-behind): consume happens in the body after resume, not in
## the magic. See experiments/actor_poc/ for the trace that proved it.
##
## MUST compile --mm:arc --panics:on (nim-cps requirement).
import cps
import ../ipc/mailbox

type
  Actor* = ref object of Continuation
    pending*:   MailMsg   ## message planted by the sender before resume
    suspended* {.cursor.}: Actor  ## self-view set while parked (nil when running);
                                  ## cursor: observation, not ownership — avoids ARC ref cycle

proc recv*(a: Actor): MailMsg {.cpsVoodoo.} =
  ## Read the message planted before this resume. Call after suspend() returns.
  a.pending

proc suspend*(a: Actor): Actor {.cpsMagic.} =
  ## Park: store self so a sender can resume us later. Reads nothing.
  a.suspended = a
  nil

proc resume*(a: Actor) =
  ## Run the actor until it next suspends (or finishes).
  discard trampoline(a)

proc deliver*(a: Actor; msg: MailMsg) =
  ## Plant a message and resume the parked actor. Precondition: actor suspended.
  assert a.suspended != nil, "deliver: actor not suspended"
  let s = a.suspended
  a.pending = msg
  s.suspended = nil          # clear before resume so the next suspend re-arms it
  resume(s)

proc isSuspended*(a: Actor): bool =
  a.suspended != nil
