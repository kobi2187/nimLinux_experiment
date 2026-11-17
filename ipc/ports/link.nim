# SPDX-License-Identifier: GPL-2.0
## The two transports of a device port, behind ONE client API (K3).
##
##   tkDirect   the device module is linked in: a request is a procedure call, an event is pushed into
##              the client's event ring by the device;
##   tkMessage  the device module is a server: requests, replies and events are channel messages.
##
## The client calls `submit`, `takeReply`, `nextEvent` the same way in both, and the device module is
## ONE `Handler` (an exhaustive `case` over its operation enum) in both. Only `submit`/`serve`/`emit`
## differ, and each `case` over `TransportKind` is exhaustive, so a third transport is a compile error
## at every place that must handle it.
##
## Requests are answered one at a time per link (a request outstanding makes the next `submit` psBusy):
## the simplest rule that keeps replies unambiguous; batching and pipelining are leaves for later.
## Events are bounded and the device is never blocked by a slow client: when a queue is full the NEWEST
## event is lost, and the next event that fits is preceded by an in-band `Lost{count}` event marking the
## gap (ipc/ports/port.nim). The same rule holds in both transports, on the device side (the ring or the
## channel is full) and on the client side (the client's ring is full while it drains the channel).
import port
import ../handles/handle_table
import ../handles/channel

const EventRingSize* = 16

type
  Handler* = proc(ctx: pointer; req: PortMsg; rep: var PortMsg) {.nimcall.}
    ## The device module's request handler. It receives a request, fills `rep` (status, payload).
    ## `rep.cls/op/seq` are set by the transport; the handler sets `status` and the payload.

  DeviceModule* = object
    handler*: Handler
    ctx*: pointer

  EventRing = object
    q: array[EventRingSize, PortMsg]
    head, count: int

  TransportKind* = enum
    tkDirect, tkMessage

  Link* = object
    ## The client's side of a bound port.
    nextSeq: uint32
    outstanding: bool            ## a request has been submitted and its reply not yet taken
    haveReply: bool
    reply: PortMsg
    ring: EventRing
    peerGone: bool
    localLost: uint32            ## events dropped because the client's own ring was full
    malformed*: int              ## messages that arrived but were not valid port messages
    case kind*: TransportKind
    of tkDirect:
      dev*: DeviceModule
    of tkMessage:
      task*: TaskId
      h*: Handle

  Emitter* = object
    ## The device module's side for sending events.
    dropped*: int                ## events the transport could not take
    case kind*: TransportKind
    of tkDirect:
      link*: ptr Link
    of tkMessage:
      task*: TaskId
      h*: Handle

# ── event ring ────────────────────────────────────────────────────────────────

proc tryPush(r: var EventRing; m: PortMsg): bool =
  if r.count == EventRingSize: return false
  r.q[(r.head + r.count) mod EventRingSize] = m
  inc r.count
  true

proc pop(r: var EventRing; m: var PortMsg): bool =
  if r.count == 0: return false
  m = r.q[r.head]
  r.head = (r.head + 1) mod EventRingSize
  dec r.count
  true

# ── construction ──────────────────────────────────────────────────────────────

proc directLink*(dev: DeviceModule): Link = Link(kind: tkDirect, dev: dev)
proc messageLink*(task: TaskId; h: Handle): Link = Link(kind: tkMessage, task: task, h: h)

proc directEmitter*(l: ptr Link): Emitter = Emitter(kind: tkDirect, link: l)
proc messageEmitter*(task: TaskId; h: Handle): Emitter = Emitter(kind: tkMessage, task: task, h: h)

# ── client side ───────────────────────────────────────────────────────────────

proc statusOf(r: ChResult): PortStatus =
  case r
  of crOk: psOk
  of crPeerClosed: psPeerGone
  of crFull: psFull
  of crTooBig: psTooBig
  of crEmpty: psPending
  of crBadHandle, crWrongType, crNoRight, crWidens, crTooManyHandles, crSelfTransfer, crTableFull,
     crNoChannels, crObjsFull, crHasHandles, crBadTask: psBadArg

proc drain(l: var Link; hs: var HandleSpace; ch: var ChannelStore) =
  ## Message transport: move everything that has arrived into the reply slot and the event ring.
  case l.kind
  of tkDirect: discard                          # direct: replies and events are already in place
  of tkMessage:
    while true:
      var buf: array[ChMsgBytes, byte]
      var n: int
      var badge: uint64
      var got: array[ChMaxFlights, Handle]
      var nGot: int
      let r = chRead(hs, ch, l.task, l.h, buf, n, badge, got, nGot)
      if r == crPeerClosed: l.peerGone = true; break
      if r != crOk: break                       # empty (or an error: nothing more to read now)
      var m: PortMsg
      if fromWire(buf.toOpenArray(0, n - 1), m) != psOk: inc l.malformed; continue
      case m.cls
      of mcReply:
        if l.outstanding and m.seq == l.nextSeq - 1: l.reply = m; l.haveReply = true
        else: inc l.malformed                   # a reply nobody asked for
      of mcEvent:
        if not tryPush(l.ring, m): inc l.localLost       # the client is not keeping up: the newest is lost
      of mcRequest: inc l.malformed             # a device never sends requests to its client

proc submit*(l: var Link; hs: var HandleSpace; ch: var ChannelStore; req: var PortMsg): PortStatus =
  ## Send a request. One at a time: psBusy while the previous reply has not been taken.
  if l.outstanding: return psBusy
  if req.cls != mcRequest: return psBadArg
  req.seq = l.nextSeq
  case l.kind
  of tkDirect:
    var rep = PortMsg(cls: mcReply, status: psOk, op: req.op, seq: req.seq)
    l.dev.handler(l.dev.ctx, req, rep)
    rep.cls = mcReply; rep.op = req.op; rep.seq = req.seq   # the transport owns these fields
    l.reply = rep; l.haveReply = true
  of tkMessage:
    var buf: array[ChMsgBytes, byte]
    let n = toWire(req, buf)
    let r = chWrite(hs, ch, l.task, l.h, buf.toOpenArray(0, n - 1))
    if r != crOk:
      if r == crPeerClosed: l.peerGone = true
      return statusOf(r)
  inc l.nextSeq
  l.outstanding = true
  psOk

proc takeReply*(l: var Link; hs: var HandleSpace; ch: var ChannelStore; rep: var PortMsg): PortStatus =
  ## The reply to the outstanding request: psOk (taken), psPending (not yet), psPeerGone (the device
  ## module is gone), psNotBound (nothing was asked).
  if not l.outstanding: return psNotBound
  drain(l, hs, ch)
  if l.haveReply:
    rep = l.reply
    l.haveReply = false; l.outstanding = false
    return psOk
  if l.peerGone: return psPeerGone
  psPending

proc nextEvent*(l: var Link; hs: var HandleSpace; ch: var ChannelStore; ev: var PortMsg): bool =
  drain(l, hs, ch)
  result = pop(l.ring, ev)
  if l.localLost > 0 and tryPush(l.ring, lostMsg(l.localLost)):   # now there is room: mark the gap, after what was kept
    l.localLost = 0
proc eventsQueued*(l: Link): int = l.ring.count   ## events ready without reading the channel
proc peerGone*(l: var Link; hs: var HandleSpace; ch: var ChannelStore): bool =
  drain(l, hs, ch)
  l.peerGone

# ── device side ───────────────────────────────────────────────────────────────

proc trySend(e: var Emitter; hs: var HandleSpace; ch: var ChannelStore; m: PortMsg): bool =
  case e.kind
  of tkDirect: tryPush(e.link.ring, m)
  of tkMessage:
    var buf: array[ChMsgBytes, byte]
    let n = toWire(m, buf)
    chWrite(hs, ch, e.task, e.h, buf.toOpenArray(0, n - 1)) == crOk

proc emit*(e: var Emitter; hs: var HandleSpace; ch: var ChannelStore; m: PortMsg) =
  ## Send an event to the client. Never blocks. If the transport is full the event is lost and counted;
  ## the next time something fits, a Lost event goes first so the client knows how many it missed.
  var ev = m
  ev.cls = mcEvent
  if e.dropped > 0:
    if not trySend(e, hs, ch, lostMsg(uint32(e.dropped))):
      inc e.dropped; return                     # still full: this one is lost too
    e.dropped = 0
  if not trySend(e, hs, ch, ev): inc e.dropped

proc serve*(hs: var HandleSpace; ch: var ChannelStore; task: TaskId; h: Handle;
            dev: DeviceModule): int =
  ## Message transport, device side: answer every request that has arrived. Returns how many.
  while true:
    var buf: array[ChMsgBytes, byte]
    var n: int
    var badge: uint64
    var got: array[ChMaxFlights, Handle]
    var nGot: int
    if chRead(hs, ch, task, h, buf, n, badge, got, nGot) != crOk: break
    var req: PortMsg
    var rep = PortMsg(cls: mcReply, status: psOk)
    if fromWire(buf.toOpenArray(0, n - 1), req) != psOk or req.cls != mcRequest:
      continue                                   # malformed: nothing to answer (no valid seq)
    rep.op = req.op; rep.seq = req.seq
    dev.handler(dev.ctx, req, rep)
    rep.cls = mcReply; rep.op = req.op; rep.seq = req.seq
    var wire: array[ChMsgBytes, byte]
    let w = toWire(rep, wire)
    discard chWrite(hs, ch, task, h, wire.toOpenArray(0, w - 1))   # a gone client: nothing to tell
    inc result
