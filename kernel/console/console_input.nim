# SPDX-License-Identifier: GPL-2.0
## Console input — the shell reads one character from whichever source has
## one: the serial line, or key events on the event bus topic "input"
## (virtio-keyboard today; an input_server later). While idle it lets the
## framebuffer console present pending output.

import std/options
import ../../core/serial
import ../../kernel/event_server
import ../../kernel/traits/event
import ../../input/evdev_keymap
import fb_console

var
  gKeys: KeyState
  gInputTok: EventToken
  gSubscribed: bool

proc keyEventChar(): int =
  ## Next character typed on the keyboard, or NoChar.
  if not gSubscribed:
    gInputTok = eventSubscribe("input")
    gSubscribed = true
  while true:
    let ev = eventPoll(gInputTok)
    if ev.isNone: return NoChar
    let p = ev.get().payload.data            # virtio_input_event: type, code, value
    let typ  = uint16(p[0]) or (uint16(p[1]) shl 8)
    let code = uint16(p[2]) or (uint16(p[3]) shl 8)
    let val  = int32(uint32(p[4]) or (uint32(p[5]) shl 8) or
                     (uint32(p[6]) shl 16) or (uint32(p[7]) shl 24))
    if typ == EvKey:
      let c = gKeys.keyToChar(code, val)
      if c != NoChar: return c

proc consoleGetChar*(): char =
  ## Block until a character arrives on serial or the keyboard.
  while true:
    let s = defaultSerial.tryGetChar()
    if s.isSome: return s.val                 # core/types Option (serial), not std
    let k = keyEventChar()
    if k != NoChar: return char(k)
    fbConsoleFlush()
