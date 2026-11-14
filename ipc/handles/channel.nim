# SPDX-License-Identifier: GPL-2.0
## Channel endpoints over the handle table (docs/proposals/capabilities.md, M1/M7).
##
## A channel is a PAIR of endpoints created together; each end is a kernel object a task holds
## through a handle. A message carries bytes and up to ChMaxFlights handles, which MOVE with it.
##   * Badge: every handle has a badge fixed by whoever issued it. A message reaches the receiver
##     stamped with the badge of the handle it was WRITTEN THROUGH. The sender cannot change it, so a
##     server knows which session it is talking to without any lookup, pid or value the client
##     controls (seL4's badged endpoints).
##   * Peer closed: when the last handle to one end is closed, the other end sees `crPeerClosed`
##     once it has read the messages that were already queued for it (Zircon's PEER_CLOSED).
##   * Ownership: a message in a queue owns its handles. If the receiving end dies unread, they are
##     released (cascading to further channel ends); nothing leaks and nothing dangles.
##   * Cycles: two channels can each hold the other's end in an unread message, with no outside
##     reference left: reference counting alone never frees them, and a hostile task could use that to
##     exhaust the tables. So an unread message belongs to its SENDER: when the sender dies, the
##     handles riding in its unread messages are released (the bytes stay readable). A leak can
##     therefore outlive only the task that made it, never the system.
## There are no names here: a channel is reached only through a handle someone was given.
## Static arrays only; the sizes are tunables, not structure.

import handle_table

const
  ChMaxChans*    = 64            ## channels (pairs of ends)
  ChQueueDepth*  = 16            ## messages queued per end
  ChMsgBytes*    = 256           ## control-plane message size; bulk data moves as buffers
  ChMaxFlights*  = 4             ## handles carried by one message

type
  ChResult* = enum
    ## The numbers are the syscall error codes (negated). 1 is "bad argument/handle" so the syscall
    ## gate's generic refusal (-1) means the same thing.
    crOk, crBadHandle, crWrongType, crNoRight, crWidens, crPeerClosed, crFull, crEmpty,
    crTooBig, crTooManyHandles, crSelfTransfer, crTableFull, crNoChannels, crObjsFull, crBadTask

  SendHandle* = object
    ## A handle to move with a message, and the rights the receiver will get (a subset).
    h*: Handle
    rights*: Rights

  Msg = object
    len: uint16
    nFlights: uint8
    sender: int16               ## the task that wrote it (see "Cycles" above)
    badge: uint64
    data: array[ChMsgBytes, byte]
    flights: array[ChMaxFlights, Flight]

  End = object
    live: bool                  ## the pair is allocated
    closed: bool                ## this end's object has been destroyed
    peer: int32
    head, count: int
    q: array[ChQueueDepth, Msg]

  ChannelStore* = object
    ends: array[ChMaxChans * 2, End]

var
  gPending: array[ChMaxChans * 2, int32]   ## ends whose objects were destroyed, still to process
  gNPending: int
  gOther: DestroyCb                        ## told about destroyed objects that are not channel ends

proc chSetDestroyHook*(cb: DestroyCb) =
  ## Called for every destroyed object that is not a channel end (e.g. a buffer to be freed).
  gOther = cb

proc chInit*(c: var ChannelStore) =
  for i in 0 ..< ChMaxChans * 2: c.ends[i] = End()
  gNPending = 0

proc fromHs(e: HsError): ChResult =
  case e
  of heOk: crOk
  of heBadTask: crBadTask
  of heBadHandle, heBadObject: crBadHandle
  of heWrongType: crWrongType
  of heNoRight: crNoRight
  of heWidens: crWidens
  of heTableFull: crTableFull
  of heObjsFull: crObjsFull

proc note(d: Destroyed) =
  ## Record a destroyed object: channel ends go on the worklist, the rest to the hook.
  if not d.happened: return
  if d.kind == okChannelEnd:
    gPending[gNPending] = d.payload
    inc gNPending
  elif gOther != nil:
    gOther(d.kind, d.payload)

proc settle(s: var HandleSpace; c: var ChannelStore) =
  ## Process destroyed ends until none is left. Dropping an end's queued messages releases their
  ## handles, which can destroy more ends: a worklist, not recursion.
  while gNPending > 0:
    dec gNPending
    let i = int(gPending[gNPending])
    if i < 0 or i >= ChMaxChans * 2 or not c.ends[i].live or c.ends[i].closed: continue
    c.ends[i].closed = true
    # drop what was queued for this end
    while c.ends[i].count > 0:
      let m = addr c.ends[i].q[c.ends[i].head]
      for k in 0 ..< int(m.nFlights):
        var d: Destroyed
        hsDropFlight(s, m.flights[k], d)
        note(d)
      c.ends[i].head = (c.ends[i].head + 1) mod ChQueueDepth
      dec c.ends[i].count
    let p = int(c.ends[i].peer)
    if c.ends[p].closed:               # both ends gone: the pair is free again
      c.ends[i] = End()
      c.ends[p] = End()

proc chCreate*(s: var HandleSpace; c: var ChannelStore; t: TaskId; rightsA, rightsB: Rights;
               badgeA, badgeB: uint64; hA, hB: var Handle): ChResult =
  ## Create a channel; task t gets BOTH ends (hand one on in a message or at spawn). The badge of an
  ## end's handle is what the OTHER side sees on every message written through it.
  hA = NoHandle; hB = NoHandle
  var pair = -1
  for p in 0 ..< ChMaxChans:
    if not c.ends[2 * p].live and not c.ends[2 * p + 1].live:
      pair = p
      break
  if pair < 0: return crNoChannels
  let a = 2 * pair
  let b = a + 1
  var oa, ob: ObjId
  var e = hsNewObject(s, okChannelEnd, int32(a), oa)
  if e != heOk: return fromHs(e)
  e = hsNewObject(s, okChannelEnd, int32(b), ob)
  if e != heOk:
    hsDiscardObject(s, oa)
    return fromHs(e)
  e = hsInstall(s, t, oa, rightsA, badgeA, hA)
  if e != heOk:
    hsDiscardObject(s, oa); hsDiscardObject(s, ob)
    return fromHs(e)
  e = hsInstall(s, t, ob, rightsB, badgeB, hB)
  if e != heOk:
    var d: Destroyed
    discard hsClose(s, t, hA, d)                       # releases oa
    hsDiscardObject(s, ob)
    hA = NoHandle; hB = NoHandle
    return fromHs(e)
  c.ends[a] = End(live: true, peer: int32(b))
  c.ends[b] = End(live: true, peer: int32(a))
  crOk

proc endOf(s: HandleSpace; t: TaskId; h: Handle; need: Rights; endIdx: var int;
           badge: var uint64; obj: var ObjId): ChResult =
  let e = hsLookup(s, t, h, okChannelEnd, need, obj, badge)
  if e != heOk: return fromHs(e)
  endIdx = int(hsObjPayload(s, obj))
  crOk

proc chWrite*(s: var HandleSpace; c: var ChannelStore; t: TaskId; h: Handle;
              data: openArray[byte]; send: openArray[SendHandle] = []): ChResult =
  ## Write a message through h (needs rtWrite). Either the whole message is queued and every
  ## listed handle has moved, or nothing has changed.
  var i: int
  var badge: uint64
  var self: ObjId
  var r = endOf(s, t, h, rtWrite, i, badge, self)
  if r != crOk: return r
  if data.len > ChMsgBytes: return crTooBig
  if send.len > ChMaxFlights: return crTooManyHandles
  let p = int(c.ends[i].peer)
  if c.ends[p].closed: return crPeerClosed
  if c.ends[p].count >= ChQueueDepth: return crFull
  # validate every handle before moving any
  for k in 0 ..< send.len:
    var o: ObjId
    var b: uint64
    var rights: Rights
    var kind: ObjKind
    let le = hsLookupAny(s, t, send[k].h, rtTransfer, kind, o, rights, b)
    if le != heOk: return fromHs(le)
    if not send[k].rights.subsetOf(rights): return crWidens
    if o == self: return crSelfTransfer                   # a channel end cannot ride its own channel
    for j in 0 ..< k:
      if send[j].h == send[k].h: return crBadHandle       # the same handle twice
  # commit
  let slot = (c.ends[p].head + c.ends[p].count) mod ChQueueDepth
  let m = addr c.ends[p].q[slot]
  m.len = uint16(data.len)
  m.nFlights = uint8(send.len)
  m.sender = int16(t)
  m.badge = badge
  for k in 0 ..< data.len: m.data[k] = data[k]
  for k in 0 ..< send.len:
    var f: Flight
    let te = hsTransferOut(s, t, send[k].h, send[k].rights, f)
    doAssert te == heOk, "validated above"
    m.flights[k] = f
  inc c.ends[p].count
  crOk

proc chRead*(s: var HandleSpace; c: var ChannelStore; t: TaskId; h: Handle;
             buf: var openArray[byte]; n: var int; badge: var uint64;
             got: var array[ChMaxFlights, Handle]; nGot: var int): ChResult =
  ## Read the next message from h's end (needs rtRead). Handles that rode along are installed in
  ## t's table. Nothing is consumed if the buffer is too small (n = needed size) or the table has
  ## no room for the handles.
  n = 0; nGot = 0
  var i: int
  var wb: uint64
  var self: ObjId
  let r = endOf(s, t, h, rtRead, i, wb, self)
  if r != crOk: return r
  if c.ends[i].count == 0:
    return (if c.ends[int(c.ends[i].peer)].closed: crPeerClosed else: crEmpty)
  let m = addr c.ends[i].q[c.ends[i].head]
  n = int(m.len)
  if n > buf.len: return crTooBig
  if int(m.nFlights) > hsFreeSlots(s, t): return crTableFull
  for k in 0 ..< n: buf[k] = m.data[k]
  badge = m.badge
  for k in 0 ..< int(m.nFlights):
    var nh: Handle
    let ie = hsTransferIn(s, t, m.flights[k], nh)
    doAssert ie == heOk, "room was checked"
    got[k] = nh
  nGot = int(m.nFlights)
  c.ends[i].head = (c.ends[i].head + 1) mod ChQueueDepth
  dec c.ends[i].count
  crOk

proc chReadable*(s: HandleSpace; c: ChannelStore; t: TaskId; h: Handle): bool =
  ## A message is waiting, or the peer has closed (reading will not block).
  var i: int
  var b: uint64
  var o: ObjId
  if endOf(s, t, h, rtNone, i, b, o) != crOk: return false
  c.ends[i].count > 0 or c.ends[int(c.ends[i].peer)].closed

proc chPeerClosed*(s: HandleSpace; c: ChannelStore; t: TaskId; h: Handle): bool =
  var i: int
  var b: uint64
  var o: ObjId
  if endOf(s, t, h, rtNone, i, b, o) != crOk: return false
  c.ends[int(c.ends[i].peer)].closed

proc chQueued*(s: HandleSpace; c: ChannelStore; t: TaskId; h: Handle): int =
  var i: int
  var b: uint64
  var o: ObjId
  if endOf(s, t, h, rtNone, i, b, o) != crOk: return -1
  c.ends[i].count

proc chLiveChannels*(c: ChannelStore): int =
  for p in 0 ..< ChMaxChans:
    if c.ends[2 * p].live: inc result

proc chClose*(s: var HandleSpace; c: var ChannelStore; t: TaskId; h: Handle): ChResult =
  var d: Destroyed
  let e = hsClose(s, t, h, d)
  if e != heOk: return fromHs(e)
  note(d)
  settle(s, c)
  crOk

proc chCloseAll*(s: var HandleSpace; c: var ChannelStore; t: TaskId) =
  ## The task died: close all its handles, release the handles riding in messages it sent and that
  ## nobody has read (their bytes stay), release what that frees, cascade.
  hsCloseAll(s, t, proc(kind: ObjKind; payload: int32) {.nimcall.} =
    note(Destroyed(happened: true, kind: kind, payload: payload)))
  for i in 0 ..< ChMaxChans * 2:
    if not c.ends[i].live or c.ends[i].closed: continue
    for k in 0 ..< c.ends[i].count:
      let m = addr c.ends[i].q[(c.ends[i].head + k) mod ChQueueDepth]
      if int(m.sender) == t and m.nFlights > 0:
        for f in 0 ..< int(m.nFlights):
          var d: Destroyed
          hsDropFlight(s, m.flights[f], d)
          note(d)
        m.nFlights = 0
  settle(s, c)
