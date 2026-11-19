# SPDX-License-Identifier: GPL-2.0
## Console input — the shell reads one character from whichever source has
## one: the serial line, or key events on the event bus topic "input"
## (virtio-keyboard today; an input_server later). While idle it lets the
## framebuffer console present pending output.

import std/options
import ../../core/serial
import ../../input/evdev_keymap
import ../../ipc/ports/input_port
import ../ports/kports
import ../handles/khandles
import fb_console

var
  gKeys: KeyState
  gGrabbed: bool           ## a program owns the display: its keys are its own (see below)

proc consoleInputGrab*(on: bool) =
  ## Input follows display ownership. While a program owns the display the console acts on no key
  ## (events that still reach it are drained, so the queue cannot fill): keys typed into the program
  ## must not also arrive in the shell's command line. Modifier state is reset at each hand-over so a
  ## held shift cannot stick across it. (A program that is granted `input` takes the port itself, and
  ## the console then receives nothing at all.)
  gGrabbed = on
  gKeys = KeyState()

proc keyEventChar(): int =
  ## Next character typed on the keyboard, or NoChar. The console is an ordinary client of the input
  ## port: it holds the port's handle unless the launcher has moved it to a program.
  let me = khMe()
  if me < 0: return NoChar
  kportConsoleEnsure(me)
  var ev: InputEvent
  while kportConsoleNextEvent(me, ev):
    if gGrabbed: continue                    # drained, not acted on
    case ev.kind
    of ikKey:
      let c = gKeys.keyToChar(ev.code, int32(ord(ev.action)))
      if c != NoChar: return c
    of ikLost: gKeys = KeyState()            # events were lost: forget held modifiers rather than guess
    of ikMotion, ikButton, ikWheel: discard  # the console has no pointer
  NoChar

proc consoleGetChar*(): char =
  ## Block until a character arrives on serial or the keyboard.
  while true:
    let s = defaultSerial.tryGetChar()
    if s.isSome: return s.val                 # core/types Option (serial), not std
    let k = keyEventChar()
    if k != NoChar: return char(k)
    fbConsoleFlush()
