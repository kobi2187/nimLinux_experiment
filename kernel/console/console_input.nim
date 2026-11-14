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
  gGrabbed: bool           ## a program owns the display: its keys are its own (see below)

proc consoleInputGrab*(on: bool) =
  ## Input follows display ownership. While a program owns the display the console
  ## still drains the key events (so its queue cannot fill) but acts on none of them:
  ## the program subscribes to the same "input" topic for its own copy, and keys typed
  ## into it must not also arrive in the shell's command line. Modifier state is reset
  ## at each hand-over so a held shift cannot stick across it.
  gGrabbed = on
  gKeys = KeyState()

proc keyEventChar(): int =
  ## Next character typed on the keyboard, or NoChar.
  if not gSubscribed:
    gInputTok = eventSubscribe("input")
    gSubscribed = true
  while true:
    let ev = eventPoll(gInputTok)
    if ev.isNone: return NoChar
    if gGrabbed: continue                    # drained, not acted on
    let p = ev.get().payload.data            # virtio_input_event: type, code, value
    let typ  = uint16(p[0]) or (uint16(p[1]) shl 8)
    let code = uint16(p[2]) or (uint16(p[3]) shl 8)
    # cast, not a conversion: a pointer's relative motion is negative (0xFFFFFFFD = -3), and
    # a checked uint32 -> int32 conversion of it is a RangeDefect (a kernel panic).
    let val  = cast[int32](uint32(p[4]) or (uint32(p[5]) shl 8) or
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
