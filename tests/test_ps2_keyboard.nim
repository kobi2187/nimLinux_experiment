# SPDX-License-Identifier: GPL-2.0
## Tests for PS/2 keyboard scancode translation
## These are pure logic tests — no real hardware needed.

import ../drivers/ps2_keyboard

proc testScancodeToAscii() =
  assert scancodeToAscii(0x1E) == 'a',  "0x1E should be 'a'"
  assert scancodeToAscii(0x30) == 'b',  "0x30 should be 'b'"
  assert scancodeToAscii(0x2E) == 'c',  "0x2E should be 'c'"
  assert scancodeToAscii(0x20) == 'd',  "0x20 should be 'd'"
  assert scancodeToAscii(0x39) == ' ',  "0x39 should be space"
  assert scancodeToAscii(0x1C) == '\n', "0x1C should be Enter"
  assert scancodeToAscii(0x0E) == '\b', "0x0E should be Backspace"
  assert scancodeToAscii(0x01) == '\x1B', "0x01 should be Escape"
  echo "PASS: scancode to ASCII mapping correct"

proc testBreakCodesIgnored() =
  # Break codes have bit 7 set (scancode OR 0x80)
  assert scancodeToAscii(0x1E or 0x80) == '\0', "A key release must return null"
  assert scancodeToAscii(0x1C or 0x80) == '\0', "Enter release must return null"
  assert scancodeToAscii(0x81'u8) == '\0',       "0x81 is a break code"
  assert scancodeToAscii(0xFF'u8) == '\0',       "0xFF is a break code"
  echo "PASS: break codes return null char"

proc testUnmappedKeys() =
  assert scancodeToAscii(0x00) == '\0', "0x00 is unmapped"
  assert scancodeToAscii(0x45) == '\0', "NumLock is unmapped in basic table"
  echo "PASS: unmapped keys return null char"

when isMainModule:
  testScancodeToAscii()
  testBreakCodesIgnored()
  testUnmappedKeys()
  echo "All PS/2 keyboard tests passed."
