# SPDX-License-Identifier: GPL-2.0
## The input port (K3, first device): what a keyboard, mouse or tablet module offers its single client.
##
## Requests (client to device, each answered): `ioInfo`, `ioFlush`.
## Events (device to client, unsolicited): key, motion, button, wheel.
## Every `case` over these enums is exhaustive on purpose: adding an operation or an event kind is a
## compile error in every place that must handle it.
import port

type
  InputOp* = enum
    ioInfo           ## reply: InputInfo
    ioFlush          ## the device module discards events it has buffered but not yet sent; reply: no payload

  InputInfo* {.packed.} = object
    keyboards*, pointers*: uint8
    queueSize*: uint16

  InputKind* = enum
    ikKey, ikMotion, ikButton, ikWheel
    ikLost           ## events were lost (the queue was full): `lost` says how many; resync

  InputEvent* = object
    case kind*: InputKind
    of ikKey:
      code*: uint16            ## evdev key code
      down*: bool
    of ikMotion:
      dx*, dy*: int32          ## relative, or absolute position when `absolute`
      absolute*: bool
    of ikButton:
      button*: uint8
      pressed*: bool
    of ikWheel:
      wheelX*, wheelY*: int16
    of ikLost:
      lost*: uint32

  # the wire payloads: flat, packed, one per event kind
  KeyWire {.packed.} = object
    code: uint16
    down: bool
  MotionWire {.packed.} = object
    dx, dy: int32
    absolute: bool
  ButtonWire {.packed.} = object
    button: uint8
    pressed: bool
  WheelWire {.packed.} = object
    x, y: int16

proc encode*(ev: InputEvent; m: var PortMsg) =
  ## Make an event message (class event, op = the kind).
  m = PortMsg(cls: mcEvent, status: psOk, op: uint16(ord(ev.kind)))
  case ev.kind
  of ikKey:    putPayload(m, KeyWire(code: ev.code, down: ev.down))
  of ikMotion: putPayload(m, MotionWire(dx: ev.dx, dy: ev.dy, absolute: ev.absolute))
  of ikButton: putPayload(m, ButtonWire(button: ev.button, pressed: ev.pressed))
  of ikWheel:  putPayload(m, WheelWire(x: ev.wheelX, y: ev.wheelY))
  of ikLost:   m = lostMsg(ev.lost)               # the reserved op, not the ordinal

proc decode*(m: PortMsg; ev: var InputEvent): PortStatus =
  ## Parse an event message. psBadOp for a kind this port does not have, psBadArg for a payload of the
  ## wrong size or a message that is not an event.
  if m.cls != mcEvent: return psBadArg
  var n: uint32
  if lostCount(m, n):
    ev = InputEvent(kind: ikLost, lost: n)
    return psOk
  if m.op == EventLostOp: return psBadArg           # a Lost event with a wrong payload
  if int(m.op) > ord(high(InputKind)): return psBadOp
  case InputKind(m.op)
  of ikKey:
    var w: KeyWire
    if not getPayload(m, w): return psBadArg
    ev = InputEvent(kind: ikKey, code: w.code, down: w.down)
  of ikMotion:
    var w: MotionWire
    if not getPayload(m, w): return psBadArg
    ev = InputEvent(kind: ikMotion, dx: w.dx, dy: w.dy, absolute: w.absolute)
  of ikButton:
    var w: ButtonWire
    if not getPayload(m, w): return psBadArg
    ev = InputEvent(kind: ikButton, button: w.button, pressed: w.pressed)
  of ikWheel:
    var w: WheelWire
    if not getPayload(m, w): return psBadArg
    ev = InputEvent(kind: ikWheel, wheelX: w.x, wheelY: w.y)
  of ikLost: return psBadOp                        # Lost travels as the reserved op, never as ordinal 4
  psOk

proc requestOp*(op: InputOp): PortMsg =
  PortMsg(cls: mcRequest, status: psOk, op: uint16(ord(op)))

proc opOf*(m: PortMsg; op: var InputOp): PortStatus =
  ## The operation a request names, or psBadOp.
  if m.cls != mcRequest: return psBadArg
  if int(m.op) > ord(high(InputOp)): return psBadOp
  op = InputOp(m.op)
  psOk
