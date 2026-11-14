# SPDX-License-Identifier: GPL-2.0
## Host tests for input/evdev_keymap.

import std/unittest
import ../input/evdev_keymap

proc typeKeys(ks: var KeyState; events: openArray[(uint16, int32)]): string =
  for (code, value) in events:
    let c = ks.keyToChar(code, value)
    if c != NoChar: result.add char(c)

suite "evdev keymap (US)":
  test "letters, digits, enter, space; releases type nothing":
    var ks: KeyState
    check ks.typeKeys([(30'u16, 1'i32), (30, 0), (48, 1), (48, 0), (57, 1), (2, 1), (28, 1)]) == "ab 1\r"

  test "shift and caps lock":
    var ks: KeyState
    check ks.typeKeys([(42'u16, 1'i32), (30, 1), (2, 1), (42, 0), (30, 1)]) == "A!a"
    check ks.typeKeys([(58'u16, 1'i32), (58, 0), (30, 1), (42, 1), (30, 1), (2, 1)]) == "Aa!"

  test "ctrl gives control codes; autorepeat repeats":
    var ks: KeyState
    check ks.typeKeys([(29'u16, 1'i32), (46, 1), (29, 0), (14, 1), (14, 2)]) == "\x03\b\b"

  test "unknown and out-of-table codes are ignored":
    var ks: KeyState
    check ks.typeKeys([(0'u16, 1'i32), (300, 1), (59, 1)]) == ""
