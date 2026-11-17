# SPDX-License-Identifier: GPL-2.0
## Device ports (K3, Option 2 chosen by the human 2026-11-16): the one official front door to a device
## module. See docs/proposals/device_ports.md.
##
## A port is TYPED: each device has a closed set of operations and events (enums), its payloads are plain
## data (checked at compile time: no pointers, bounded size), and every handler is an exhaustive `case`,
## so a new operation is a compile error wherever it is not handled. The same definition travels by a
## direct call (device module in the kernel) or by a channel (device module as a server): the client is
## written once (ipc/ports/link.nim).
##
## This module: the wire message, the status codes, payload packing, and the EXCLUSIVE BINDING: a port
## kind has at most one holder; the holder's handle is an `okPortClient` object that cannot be
## duplicated (no rtDuplicate), moves like any handle, and unbinds the port when its last reference dies
## (the holder's death). Pure, static arrays only; host-tested (tests/test_ports.nim).
import std/typetraits
import ../handles/handle_table
import ../handles/channel

const
  PortHeaderBytes* = 12
  PortInline* = ChMsgBytes - PortHeaderBytes      ## payload bytes of one port message

const PortDescribeOp* = 0xFFFE'u16
  ## Reserved request op every port answers (by the transport, not the device): "which port are you?".
  ## Reply payload: one byte, the PortKind ordinal. How a program finds the port among its handles.

type
  PortKind* = enum
    pkInput          ## keyboards, mice, tablets (the first port)

  PortStatus* = enum
    psOk, psPending, psBadOp, psBadArg, psTooBig, psBusy, psNotBound, psPeerGone, psFull, psNoResource

  MsgClass* = enum
    mcRequest, mcReply, mcEvent

  PortMsg* = object
    ## One port message. `op` is the ordinal of the device's operation or event enum.
    cls*: MsgClass
    status*: PortStatus
    op*: uint16
    seq*: uint32
    len*: uint16
    data*: array[PortInline, byte]

static:
  doAssert PortHeaderBytes + PortInline == ChMsgBytes, "a port message fits one channel message exactly"

# ── payloads: plain data only ─────────────────────────────────────────────────

proc putPayload*[T](m: var PortMsg; v: T) =
  ## Store a payload. Compile-time: T has no pointers or strings (it crosses a task boundary) and fits.
  static:
    doAssert supportsCopyMem(T), "a port payload must be plain data: no pointers, strings or sequences"
    doAssert sizeof(T) <= PortInline, "a port payload must fit one message"
  copyMem(addr m.data[0], unsafeAddr v, sizeof(T))
  m.len = uint16(sizeof(T))

proc getPayload*[T](m: PortMsg; v: var T): bool =
  ## Read a payload of exactly T's size; false if the message carries something else.
  static:
    doAssert supportsCopyMem(T), "a port payload must be plain data: no pointers, strings or sequences"
    doAssert sizeof(T) <= PortInline
  if int(m.len) != sizeof(T): return false
  copyMem(addr v, unsafeAddr m.data[0], sizeof(T))
  true

# ── lost events ───────────────────────────────────────────────────────────────
# Events are bounded: when a queue is full the NEWEST event is lost, and the device later sends one
# in-band `Lost{count}` event (reserved op) marking the gap, so a client can resync (for input: release
# every key it thinks is down). The same rule holds over both transports.

const EventLostOp* = 0xFFFF'u16

type LostWire {.packed.} = object
  count: uint32

proc lostMsg*(count: uint32): PortMsg =
  result = PortMsg(cls: mcEvent, status: psOk, op: EventLostOp)
  putPayload(result, LostWire(count: count))

proc lostCount*(m: PortMsg; count: var uint32): bool =
  ## Is m a Lost event, and how many events did it stand for?
  if m.cls != mcEvent or m.op != EventLostOp: return false
  var w: LostWire
  if not getPayload(m, w): return false
  count = w.count
  true

# ── wire form ─────────────────────────────────────────────────────────────────
# byte 0 class, 1 status, 2-3 op, 4-7 seq, 8-9 len, 10-11 zero, then len bytes of payload.

proc toWire*(m: PortMsg; buf: var array[ChMsgBytes, byte]): int =
  ## Bytes to write into a channel message.
  buf[0] = byte(ord(m.cls)); buf[1] = byte(ord(m.status))
  buf[2] = byte(m.op and 0xFF); buf[3] = byte(m.op shr 8)
  for i in 0 ..< 4: buf[4 + i] = byte((m.seq shr (8 * i)) and 0xFF)
  buf[8] = byte(m.len and 0xFF); buf[9] = byte(m.len shr 8)
  buf[10] = 0; buf[11] = 0
  let n = min(int(m.len), PortInline)
  for i in 0 ..< n: buf[PortHeaderBytes + i] = m.data[i]
  PortHeaderBytes + n

proc fromWire*(buf: openArray[byte]; m: var PortMsg): PortStatus =
  ## Validate and parse bytes that came off a channel. Anything malformed is refused whole.
  if buf.len < PortHeaderBytes: return psBadArg
  if int(buf[0]) > ord(high(MsgClass)) or int(buf[1]) > ord(high(PortStatus)): return psBadArg
  let len = int(buf[8]) or (int(buf[9]) shl 8)
  if len > PortInline or buf.len != PortHeaderBytes + len: return psBadArg
  m = PortMsg(cls: MsgClass(buf[0]), status: PortStatus(buf[1]),
              op: uint16(buf[2]) or (uint16(buf[3]) shl 8), len: uint16(len))
  for i in 0 ..< 4: m.seq = m.seq or (uint32(buf[4 + i]) shl (8 * i))
  for i in 0 ..< len: m.data[i] = buf[PortHeaderBytes + i]
  psOk

# ── exclusive binding ─────────────────────────────────────────────────────────

const
  PortRights* = rtRead or rtWrite or rtWait or rtTransfer
    ## What the holder gets. No rtDuplicate: a second copy would be a second holder.

type
  Binding = object
    live: bool
    obj: ObjId

  PortRegistry* = object
    b: array[PortKind, Binding]

proc portBind*(hs: var HandleSpace; reg: var PortRegistry; kind: PortKind; t: TaskId;
               h: var Handle): PortStatus =
  ## Make task t the holder of the port. Exactly one holder per kind: a second bind is psBusy.
  h = NoHandle
  if reg.b[kind].live: return psBusy
  var o: ObjId
  if hsNewObject(hs, okPortClient, int32(ord(kind)), o) != heOk: return psNoResource
  if hsInstall(hs, t, o, PortRights, 0, h) != heOk:
    hsDiscardObject(hs, o)
    return psNoResource
  reg.b[kind] = Binding(live: true, obj: o)
  psOk

proc portOnDestroyed*(reg: var PortRegistry; kind: ObjKind; payload: int32) =
  ## Install as (part of) the handle space's destroy callback: the last reference to a port object
  ## died (the holder exited or closed it), so the port is free again.
  case kind
  of okPortClient:
    doAssert payload >= 0 and payload <= int32(ord(high(PortKind))), "a port object with an unknown kind"
    reg.b[PortKind(payload)] = Binding()
  of okNone, okChannelEnd, okBuffer, okWait, okProcess:
    discard                                    # not ours

proc portUse*(hs: HandleSpace; t: TaskId; h: Handle; kind: PortKind; need: Rights): PortStatus =
  ## May task t use handle h as the port `kind` with rights `need`? (What an operation's syscall asks.)
  var o: ObjId
  var badge: uint64
  if hsLookup(hs, t, h, okPortClient, need, o, badge) != heOk: return psNotBound
  if hsObjPayload(hs, o) != int32(ord(kind)): return psBadArg     # a handle to a different port
  psOk

proc portHeld*(reg: PortRegistry; kind: PortKind): bool = reg.b[kind].live

proc checkInvariants*(reg: PortRegistry; hs: HandleSpace): string =
  ## "" when sound; else what is violated, in words.
  for k in PortKind:
    let b = reg.b[k]
    if not b.live: continue
    if hsObjKind(hs, b.obj) != okPortClient: return "port: a bound port's object is not a port object"
    if hsObjPayload(hs, b.obj) != int32(ord(k)): return "port: a bound port's object names another port"
    if hsObjRefs(hs, b.obj) != 1: return "port: a port has more than one holder (it was duplicated)"
  ""
