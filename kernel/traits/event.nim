# SPDX-License-Identifier: GPL-2.0
## Event System Trait — Interface types only
##
## All tiers use this API. No hardware dependencies — safe to import anywhere.

const
  MaxTopicLen*        = 64    ## Maximum topic string length (including null)
  MaxPayloadLen*      = 512   ## Maximum event payload bytes
  MaxSubscribers*     = 256   ## Maximum total subscriptions across all topics
  MaxPendingPerToken* = 16    ## Per-token ring buffer depth (power of 2)

type
  EventToken* = distinct uint32
    ## Opaque subscription handle returned by eventSubscribe().

  EventPayload* = object
    len*:  uint16
    data*: array[MaxPayloadLen, byte]

  Event* = object
    topic*:   array[MaxTopicLen, char]
    payload*: EventPayload
    seqNum*:  uint64   ## Monotonically increasing sequence number

proc isValid*(t: EventToken): bool {.inline.} =
  ## A zero token is invalid (never returned by eventSubscribe).
  uint32(t) != 0
