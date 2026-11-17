# SPDX-License-Identifier: GPL-2.0
## evdev triples to typed input events (K3: the input device module's decoder).
##
## virtio-input delivers Linux evdev events: (type, code, value). A pointer reports in pieces (REL_X, then
## REL_Y, then a SYN_REPORT that closes the group), a key in one event. This decoder turns the stream into
## the typed events of the input port (ipc/ports/input_port.nim): keys and buttons at once; motion and
## wheel once per SYN_REPORT (relative motion is summed over the group; a tablet's absolute position is
## the latest of each axis). Anything it does not know is dropped, never guessed. Pure, no allocation.
import ../ipc/ports/input_port

const
  EvSyn* = 0'u16
  EvKey* = 1'u16
  EvRel* = 2'u16
  EvAbs* = 3'u16
  SynReport = 0'u16
  RelX = 0'u16
  RelY = 1'u16
  RelHWheel = 6'u16
  RelWheel = 8'u16
  AbsX = 0'u16
  AbsY = 1'u16
  BtnFirst = 0x110'u16                ## BTN_MOUSE .. BTN_TASK are buttons, everything below is a key
  BtnLast = 0x117'u16
  MaxOut* = 3                         ## one feed yields at most: flushed motion, flushed wheel, the event itself

type
  EvdevDecoder* = object
    relX, relY: int64
    wheelX, wheelY: int64
    absX, absY: int32
    absDirty: bool

func clamp32(v: int64): int32 =
  if v > high(int32): high(int32) elif v < low(int32): low(int32) else: int32(v)

func pending(d: EvdevDecoder): bool =
  d.relX != 0 or d.relY != 0 or d.wheelX != 0 or d.wheelY != 0 or d.absDirty

proc flush(d: var EvdevDecoder; outEv: var array[MaxOut, InputEvent]; n: var int) =
  ## Emit what has accumulated (motion first, then wheel).
  if d.relX != 0 or d.relY != 0:
    outEv[n] = InputEvent(kind: ikMotion, dx: clamp32(d.relX), dy: clamp32(d.relY), absolute: false); inc n
  if d.absDirty:
    outEv[n] = InputEvent(kind: ikMotion, dx: d.absX, dy: d.absY, absolute: true); inc n
  if d.wheelX != 0 or d.wheelY != 0:
    outEv[n] = InputEvent(kind: ikWheel, wheelX: int16(max(-32768'i64, min(32767'i64, d.wheelX))),
                          wheelY: int16(max(-32768'i64, min(32767'i64, d.wheelY)))); inc n
  d.relX = 0; d.relY = 0; d.wheelX = 0; d.wheelY = 0; d.absDirty = false

proc feed*(d: var EvdevDecoder; typ, code: uint16; value: int32;
           outEv: var array[MaxOut, InputEvent]): int =
  ## Consume one evdev event; returns how many typed events are ready in `outEv` (0..MaxOut).
  var n = 0
  case typ
  of EvSyn:
    if code == SynReport: flush(d, outEv, n)
  of EvKey:
    var action: KeyAction
    case value
    of 0: action = kaUp
    of 1: action = kaDown
    of 2: action = kaRepeat
    else: return 0                                   # not a value a key has: drop it
    flush(d, outEv, n)                               # keep order: motion before the click it precedes
    if code >= BtnFirst and code <= BtnLast:
      outEv[n] = InputEvent(kind: ikButton, button: code, pressed: action != kaUp)
    else:
      outEv[n] = InputEvent(kind: ikKey, code: code, action: action)
    inc n
  of EvRel:
    case code
    of RelX: d.relX += int64(value)
    of RelY: d.relY += int64(value)
    of RelWheel: d.wheelY += int64(value)
    of RelHWheel: d.wheelX += int64(value)
    else: discard                                    # an axis we do not report
  of EvAbs:
    case code
    of AbsX: d.absX = value; d.absDirty = true
    of AbsY: d.absY = value; d.absDirty = true
    else: discard
  else: discard                                      # LEDs, switches, misc: not input events here
  n
