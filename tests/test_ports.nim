# SPDX-License-Identifier: GPL-2.0
## Device ports (ipc/ports): the wire form, the typed input port, the exclusive binding, and that ONE
## scenario passes unchanged over BOTH transports (direct call and channel messages).
import std/unittest
import ../ipc/handles/handle_table
import ../ipc/handles/channel
import ../ipc/ports/port
import ../ipc/ports/input_port
import ../ipc/ports/display_port
import ../ipc/ports/link

var
  hs: HandleSpace
  ch: ChannelStore
  reg: PortRegistry

proc onDestroyed(kind: ObjKind; payload: int32) {.nimcall.} = portOnDestroyed(reg, kind, payload)

proc fresh() =
  hsInit(hs); chInit(ch); reg = PortRegistry()
  check hsAttach(hs, 0) == heOk
  check hsAttach(hs, 1) == heOk

# ── the device module under test: ONE handler used by both transports ─────────

type DeviceState = object
  infoCalls, flushes: int

proc inputHandler(ctx: pointer; req: PortMsg; rep: var PortMsg) {.nimcall.} =
  let st = cast[ptr DeviceState](ctx)
  var op: InputOp
  let s = opOf(req, op)
  if s != psOk: rep.status = s; return
  case op                                       # exhaustive: a new InputOp will not compile until handled
  of ioInfo:
    inc st.infoCalls
    putPayload(rep, InputInfo(keyboards: 1, pointers: 2, queueSize: EventRingSize))
  of ioFlush:
    inc st.flushes

suite "port wire form":
  test "a message round-trips through bytes":
    var m = PortMsg(cls: mcReply, status: psBadOp, op: 0x1234, seq: 0xDEADBEEF'u32)
    putPayload(m, InputInfo(keyboards: 3, pointers: 4, queueSize: 77))
    var buf: array[ChMsgBytes, byte]
    let n = toWire(m, buf)
    check n == PortHeaderBytes + sizeof(InputInfo)
    var back: PortMsg
    check fromWire(buf.toOpenArray(0, n - 1), back) == psOk
    check back.cls == mcReply and back.status == psBadOp and back.op == 0x1234 and back.seq == 0xDEADBEEF'u32
    var info: InputInfo
    check getPayload(back, info) and info.keyboards == 3 and info.pointers == 4 and info.queueSize == 77

  test "malformed bytes are refused whole":
    var m = PortMsg(cls: mcRequest, op: 1)
    var buf: array[ChMsgBytes, byte]
    let n = toWire(m, buf)
    var back: PortMsg
    check fromWire(buf.toOpenArray(0, PortHeaderBytes - 2), back) == psBadArg        # short
    check fromWire(buf.toOpenArray(0, n), back) == psBadArg                           # trailing byte
    var bad = buf; bad[0] = 9                                                         # unknown class
    check fromWire(bad.toOpenArray(0, n - 1), back) == psBadArg
    bad = buf; bad[1] = 200                                                           # unknown status
    check fromWire(bad.toOpenArray(0, n - 1), back) == psBadArg
    bad = buf; bad[8] = 0xFF; bad[9] = 0xFF                                           # length beyond the message
    check fromWire(bad.toOpenArray(0, n - 1), back) == psBadArg

  test "a payload is read back only as exactly what was put":
    var m = PortMsg(cls: mcReply)
    putPayload(m, InputInfo(keyboards: 1))
    var other: int64
    check not getPayload(m, other)               # wrong size
    var info: InputInfo
    check getPayload(m, info)

suite "input port":
  test "every event kind survives encode/decode":
    let evs = [InputEvent(kind: ikKey, code: 30, action: kaDown),
               InputEvent(kind: ikMotion, dx: -5, dy: 700, absolute: true),
               InputEvent(kind: ikButton, button: 273, pressed: true),
               InputEvent(kind: ikWheel, wheelX: -1, wheelY: 3),
               InputEvent(kind: ikLost, lost: 12345)]
    for ev in evs:
      var m: PortMsg
      encode(ev, m)
      check m.cls == mcEvent
      var back: InputEvent
      check decode(m, back) == psOk
      check back.kind == ev.kind
      case ev.kind
      of ikKey:    check back.code == ev.code and back.action == ev.action
      of ikMotion: check back.dx == ev.dx and back.dy == ev.dy and back.absolute == ev.absolute
      of ikButton: check back.button == ev.button and back.pressed == ev.pressed
      of ikWheel:  check back.wheelX == ev.wheelX and back.wheelY == ev.wheelY
      of ikLost:   check back.lost == ev.lost and m.op == EventLostOp

  test "hostile events are refused":
    var ev: InputEvent
    var m = PortMsg(cls: mcEvent, op: 99)
    check decode(m, ev) == psBadOp
    m = PortMsg(cls: mcEvent, op: uint16(ord(ikKey)), len: 1)    # wrong payload size
    check decode(m, ev) == psBadArg
    m = PortMsg(cls: mcReply, op: 0)                              # not an event
    check decode(m, ev) == psBadArg
    m = PortMsg(cls: mcEvent, op: uint16(ord(ikLost)))            # Lost has its own reserved op, not its ordinal
    check decode(m, ev) == psBadOp
    m = PortMsg(cls: mcEvent, op: EventLostOp, len: 1)            # a Lost event with a wrong payload
    check decode(m, ev) == psBadArg

suite "exclusive binding":
  test "one holder; no duplicate; moves keep it exclusive; death frees it":
    fresh()
    var h: Handle
    check portBind(hs, reg, pkInput, 0, h) == psOk
    check portHeld(reg, pkInput) and checkInvariants(reg, hs) == ""
    var h2: Handle
    check portBind(hs, reg, pkInput, 1, h2) == psBusy                    # a second client is refused
    check portUse(hs, 0, h, pkInput, rtRead or rtWrite) == psOk
    check portUse(hs, 1, h, pkInput, rtRead) == psNotBound               # another task's value means nothing
    check portUse(hs, 0, Handle(0x12345), pkInput, rtRead) == psNotBound # a forged value
    var copy: Handle
    check hsDuplicate(hs, 0, h, rtRead, copy) == heNoRight                # there is no second copy to hold
    # the holder passes it on: the first loses it, the second holds it, the port stays taken
    var f: Flight
    check hsTransferOut(hs, 0, h, PortRights, f) == heOk
    check portUse(hs, 0, h, pkInput, rtRead) == psNotBound
    var moved: Handle
    check hsTransferIn(hs, 1, f, moved) == heOk
    check portUse(hs, 1, moved, pkInput, rtRead) == psOk
    check portBind(hs, reg, pkInput, 0, h2) == psBusy
    check checkInvariants(reg, hs) == ""
    # the new holder dies: the port is free again
    hsCloseAll(hs, 1, onDestroyed)
    check not portHeld(reg, pkInput)
    check hsAttach(hs, 1) == heOk
    check portBind(hs, reg, pkInput, 1, h2) == psOk
    check checkInvariants(reg, hs) == ""

# ── ONE scenario, both transports ─────────────────────────────────────────────

type Pump = proc() {.closure.}

proc scenario(l: var Link; em: var Emitter; pump: Pump; dev: ptr DeviceState) =
  var rep: PortMsg
  # a request is answered with a typed reply
  var req = requestOp(ioInfo)
  check submit(l, hs, ch, req) == psOk
  var again = requestOp(ioInfo)
  check submit(l, hs, ch, again) == psBusy                               # one outstanding request at a time
  pump()
  check takeReply(l, hs, ch, rep) == psOk
  check rep.cls == mcReply and rep.status == psOk and rep.op == uint16(ord(ioInfo)) and rep.seq == req.seq
  var info: InputInfo
  check getPayload(rep, info) and info.keyboards == 1 and info.pointers == 2
  check takeReply(l, hs, ch, rep) == psNotBound                          # nothing is outstanding now
  # an operation the device does not have is refused by the device, with a status, not a crash
  var bogus = PortMsg(cls: mcRequest, op: 99)
  check submit(l, hs, ch, bogus) == psOk
  pump()
  check takeReply(l, hs, ch, rep) == psOk and rep.status == psBadOp
  # a request with no payload and no answer data
  var fl = requestOp(ioFlush)
  check submit(l, hs, ch, fl) == psOk
  pump()
  check takeReply(l, hs, ch, rep) == psOk and rep.status == psOk and rep.len == 0
  check dev.infoCalls == 1 and dev.flushes == 1
  # events arrive in order, and all of them
  let evs = [InputEvent(kind: ikKey, code: 30, action: kaDown), InputEvent(kind: ikKey, code: 30, action: kaUp),
             InputEvent(kind: ikMotion, dx: 3, dy: -4), InputEvent(kind: ikWheel, wheelY: 1)]
  for ev in evs:
    var m: PortMsg
    encode(ev, m)
    emit(em, hs, ch, m)
  for ev in evs:
    var m: PortMsg
    check nextEvent(l, hs, ch, m)
    var back: InputEvent
    check decode(m, back) == psOk and back.kind == ev.kind
  var none: PortMsg
  check not nextEvent(l, hs, ch, none)
  # a client that falls behind loses the NEWEST events and is told how many (one rule, both transports)
  const Sent = 100
  for i in 0 ..< Sent:
    var m: PortMsg
    encode(InputEvent(kind: ikKey, code: uint16(i), action: kaDown), m)
    emit(em, hs, ch, m)
  var received, lost = 0
  var m1: PortMsg
  var nextCode = 0
  while nextEvent(l, hs, ch, m1):
    var e: InputEvent
    check decode(m1, e) == psOk
    case e.kind
    of ikKey:
      check int(e.code) == nextCode                  # what was kept is a contiguous prefix, in order
      inc nextCode; inc received
    of ikLost: lost += int(e.lost)
    of ikMotion, ikButton, ikWheel: check false
  check received >= 1 and received < Sent             # it really did overflow
  # the gap is announced by the next event that fits: send a sentinel and read it
  var sentinel: PortMsg
  encode(InputEvent(kind: ikWheel, wheelY: 9), sentinel)
  emit(em, hs, ch, sentinel)
  var sawSentinel = false
  while nextEvent(l, hs, ch, m1):
    var e: InputEvent
    check decode(m1, e) == psOk
    case e.kind
    of ikLost: lost += int(e.lost)
    of ikWheel: sawSentinel = true
    of ikKey, ikMotion, ikButton: check false
  check sawSentinel
  check received + lost == Sent                         # every event is either delivered or counted as lost

suite "one scenario, two transports":
  test "direct call":
    fresh()
    var dev: DeviceState
    var l = directLink(DeviceModule(handler: inputHandler, ctx: addr dev))
    var em = directEmitter(addr l)
    scenario(l, em, proc() = discard, addr dev)

  test "channel messages":
    fresh()
    var dev: DeviceState
    var a, b0, b1: Handle
    check chCreate(hs, ch, 0, rtChannelDefault, rtChannelDefault, 0, 0, a, b0) == crOk
    var f: Flight
    check hsTransferOut(hs, 0, b0, rtChannelDefault, f) == heOk
    check hsTransferIn(hs, 1, f, b1) == heOk
    var l = messageLink(0, a)
    var em = messageEmitter(1, b1)
    let module = DeviceModule(handler: inputHandler, ctx: addr dev)
    scenario(l, em, proc() = discard serve(hs, ch, 1, b1, module), addr dev)
    check l.malformed == 0

  test "message transport: no pump yet means pending; a vanished device module is reported":
    fresh()
    var dev: DeviceState
    var a, b0, b1: Handle
    check chCreate(hs, ch, 0, rtChannelDefault, rtChannelDefault, 0, 0, a, b0) == crOk
    var f: Flight
    check hsTransferOut(hs, 0, b0, rtChannelDefault, f) == heOk
    check hsTransferIn(hs, 1, f, b1) == heOk
    var l = messageLink(0, a)
    var rep: PortMsg
    var req = requestOp(ioInfo)
    check submit(l, hs, ch, req) == psOk
    check takeReply(l, hs, ch, rep) == psPending                          # the server has not run yet
    check chClose(hs, ch, 1, b1) == crOk                                  # the device module goes away
    check takeReply(l, hs, ch, rep) == psPeerGone
    check peerGone(l, hs, ch)
    discard dev

  test "garbage on the wire is counted, never acted on":
    fresh()
    var a, b0, b1: Handle
    check chCreate(hs, ch, 0, rtChannelDefault, rtChannelDefault, 0, 0, a, b0) == crOk
    var f: Flight
    check hsTransferOut(hs, 0, b0, rtChannelDefault, f) == heOk
    check hsTransferIn(hs, 1, f, b1) == heOk
    var l = messageLink(0, a)
    check chWrite(hs, ch, 1, b1, [byte 1, 2, 3]) == crOk                   # not a port message
    var m: PortMsg
    check not nextEvent(l, hs, ch, m)
    check l.malformed == 1

suite "display port":
  test "every operation names itself; hostile ops are refused":
    for op in DisplayOp:
      var m = displayRequest(op)
      var back: DisplayOp
      check displayOpOf(m, back) == psOk and back == op
    var m = PortMsg(cls: mcRequest, op: 99)
    var back: DisplayOp
    check displayOpOf(m, back) == psBadOp
    m = PortMsg(cls: mcReply, op: 0)
    check displayOpOf(m, back) == psBadArg

  test "payloads fit one message and round-trip":
    var m = PortMsg(cls: mcReply)
    var modes: DisplayModesWire
    modes.count = 3
    modes.modes[0] = ModeWire(w: 800, h: 600)
    modes.modes[2] = ModeWire(w: 1280, h: 800)
    putPayload(m, modes)
    var back: DisplayModesWire
    check getPayload(m, back) and back.count == 3 and back.modes[2].w == 1280
    var p = PortMsg(cls: mcRequest)
    putPayload(p, PresentWire(handle: 7, strideBytes: 2560, sx: 0, sy: 0, w: 640, h: 400, dx: 10, dy: -1))
    var pw: PresentWire
    check getPayload(p, pw) and pw.handle == 7 and pw.dy == -1 and pw.w == 640

  test "a display handle and an input handle are different ports (exclusive separately)":
    fresh()
    var hi, hd, hd2: Handle
    check portBind(hs, reg, pkInput, 0, hi) == psOk
    check portBind(hs, reg, pkDisplay, 1, hd) == psOk               # the input holder does not block the display
    check portBind(hs, reg, pkDisplay, 0, hd2) == psBusy
    check portUse(hs, 1, hd, pkInput, rtRead) == psBadArg           # a display handle is not an input handle
    check portUse(hs, 1, hd, pkDisplay, rtRead) == psOk
    check checkInvariants(reg, hs) == ""
    hsCloseAll(hs, 1, onDestroyed)
    check not portHeld(reg, pkDisplay) and portHeld(reg, pkInput)
