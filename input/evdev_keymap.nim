# SPDX-License-Identifier: GPL-2.0
## evdev key events → characters (US layout). Pure: the caller feeds
## (code, value) pairs from any source — virtio-input today, an
## input_server later — and keeps the modifier state.

const
  EvKey* = 1'u16                 ## evdev event type for keys
  KeyLeftCtrl = 29'u16
  KeyLeftShift = 42'u16
  KeyRightShift = 54'u16
  KeyCapsLock = 58'u16
  KeyRightCtrl = 97'u16
  NoChar* = -1

  # Index = evdev keycode (KEY_ESC = 1 … KEY_SPACE = 57); '\0' = no character.
  Plain = "\0\e1234567890-=\b\tqwertyuiop[]\r\0asdfghjkl;'`\0\\zxcvbnm,./\0*\0 "
  Shifted = "\0\e!@#$%^&*()_+\b\tQWERTYUIOP{}\r\0ASDFGHJKL:\"~\0|ZXCVBNM<>?\0*\0 "

type
  KeyState* = object
    shift, ctrl, caps: bool

func isLetter(c: char): bool {.inline.} = c in 'a' .. 'z' or c in 'A' .. 'Z'

proc trackModifier(ks: var KeyState; code: uint16; down: bool): bool =
  ## Update modifier state; true if `code` was a modifier.
  case code
  of KeyLeftShift, KeyRightShift: ks.shift = down
  of KeyLeftCtrl, KeyRightCtrl:   ks.ctrl = down
  of KeyCapsLock:                 (if down: ks.caps = not ks.caps)
  else: return false
  true

proc keyToChar*(ks: var KeyState; code: uint16; value: int32): int =
  ## Feed one EV_KEY event (value 1 = press, 2 = autorepeat, 0 = release).
  ## Returns the character typed, or NoChar.
  if ks.trackModifier(code, value != 0) or value == 0: return NoChar
  if int(code) >= Plain.len: return NoChar
  var c = if ks.shift: Shifted[int(code)] else: Plain[int(code)]
  if c == '\0': return NoChar
  if ks.caps and isLetter(c):                 # caps inverts the letter case
    c = if c in 'a' .. 'z': char(ord(c) - 32) else: char(ord(c) + 32)
  if ks.ctrl and isLetter(c):                 # Ctrl-A … Ctrl-Z → 0x01 … 0x1A
    return (ord(c) or 0x20) - ord('a') + 1
  ord(c)
