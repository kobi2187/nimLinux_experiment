# SPDX-License-Identifier: GPL-2.0
## Actor scheduler — pumps actors whose inbox has a message.
##
## cps ships no scheduler; this is ours. Each registered actor is pumped (one
## message consumed) whenever its inbox is non-empty. Single-threaded, no locks —
## the soft-RT concurrency hub. Scales with actor count, not OS threads (no
## kernel stack per actor). See runtime/actor.nim for the proven pump idiom.
##
## MUST compile --mm:arc --panics:on.
import actor

const MaxActors* = 64

type
  ActorSched* = object
    actors*: array[MaxActors, Actor]
    count*:  int

proc schedInit*(s: var ActorSched) =
  s.count = 0
  for i in 0..<MaxActors: s.actors[i] = nil

proc schedAdd*(s: var ActorSched; a: Actor) =
  ## Register an actor (freshly whelped; not yet pumped).
  assert a != nil, "schedAdd: nil actor"
  if s.count >= MaxActors: return
  s.actors[s.count] = a
  inc s.count

proc runOnce*(s: var ActorSched) =
  ## One scheduling pass: pump every actor whose inbox has a message.
  ## Pumping consumes exactly one message per actor; repeated passes drain more.
  for i in 0..<s.count:
    let a = s.actors[i]
    if a != nil and inboxReady(a.inbox):
      s.actors[i] = pump(a)
