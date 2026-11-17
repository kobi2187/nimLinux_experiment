# SPDX-License-Identifier: GPL-2.0
## evdev triples to typed input events (input/evdev_decode.nim).
import std/[unittest, random]
import ../ipc/ports/input_port
import ../input/evdev_decode

proc run(d: var EvdevDecoder; evs: openArray[(uint16, uint16, int32)]): seq[InputEvent] =
  for (t, c, v) in evs:
    var o: array[MaxOut, InputEvent]
    let n = d.feed(t, c, v, o)
    for i in 0 ..< n: result.add o[i]

suite "evdev decoder":
  test "keys: press, repeat and release are typed actions":
    var d: EvdevDecoder
    let r = d.run([(EvKey, 30'u16, 1'i32), (EvKey, 30, 2), (EvKey, 30, 0), (EvSyn, 0, 0)])
    check r.len == 3
    check r[0].kind == ikKey and r[0].code == 30 and r[0].action == kaDown
    check r[1].action == kaRepeat and r[2].action == kaUp

  test "a value no key has is dropped, not guessed":
    var d: EvdevDecoder
    check d.run([(EvKey, 30'u16, 7'i32), (EvKey, 30, -1)]).len == 0

  test "mouse motion is summed over a SYN group and emitted once":
    var d: EvdevDecoder
    let r = d.run([(EvRel, 0'u16, 5'i32), (EvRel, 0, 3), (EvRel, 1, -4), (EvSyn, 0, 0)])
    check r.len == 1 and r[0].kind == ikMotion and not r[0].absolute and r[0].dx == 8 and r[0].dy == -4
    check d.run([(EvSyn, 0'u16, 0'i32)]).len == 0            # nothing pending: nothing emitted

  test "tablet position is absolute and keeps the other axis":
    var d: EvdevDecoder
    var r = d.run([(EvAbs, 0'u16, 1000'i32), (EvAbs, 1, 2000), (EvSyn, 0, 0)])
    check r.len == 1 and r[0].absolute and r[0].dx == 1000 and r[0].dy == 2000
    r = d.run([(EvAbs, 0'u16, 1500'i32), (EvSyn, 0, 0)])        # only X moved
    check r.len == 1 and r[0].dx == 1500 and r[0].dy == 2000

  test "wheel, horizontal wheel and buttons":
    var d: EvdevDecoder
    var r = d.run([(EvRel, 8'u16, 1'i32), (EvRel, 6, -2), (EvSyn, 0, 0)])
    check r.len == 1 and r[0].kind == ikWheel and r[0].wheelY == 1 and r[0].wheelX == -2
    r = d.run([(EvKey, 272'u16, 1'i32), (EvKey, 272, 0), (EvKey, 273, 1)])
    check r.len == 3 and r[0].kind == ikButton and r[0].button == 272 and r[0].pressed
    check not r[1].pressed and r[2].button == 273

  test "pending motion is delivered BEFORE the click that follows it (order kept)":
    var d: EvdevDecoder
    let r = d.run([(EvRel, 0'u16, 9'i32), (EvKey, 272, 1)])
    check r.len == 2 and r[0].kind == ikMotion and r[0].dx == 9 and r[1].kind == ikButton

  test "unknown event types and axes are ignored; huge motion saturates":
    var d: EvdevDecoder
    check d.run([(17'u16, 0'u16, 1'i32), (EvRel, 9, 5), (EvAbs, 40, 5), (EvSyn, 3, 0)]).len == 0
    let r = d.run([(EvRel, 0'u16, high(int32)), (EvRel, 0, high(int32)), (EvSyn, 0, 0)])
    check r.len == 1 and r[0].dx == high(int32)

  test "random streams never crash and never yield more than MaxOut per feed":
    var d: EvdevDecoder
    var rng = initRand(3)
    for i in 0 ..< 50000:
      var o: array[MaxOut, InputEvent]
      let n = d.feed(uint16(rng.rand(5)), uint16(rng.rand(300)), int32(rng.rand(-3 .. 5)), o)
      check n >= 0 and n <= MaxOut
