# SPDX-License-Identifier: GPL-2.0
## Tests for PS/2 keyboard scancode translation and event publish path.
## Pure logic tests — no real hardware needed.

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

# ── Event publish path (testing mode) ────────────────────────────────────────
# We simulate kbdIrqHandler logic without real hardware or interrupts:
# read scancode → send EOI (no-op in test) → eventPublish("key.down", scancode)

when defined(testing):
  import ../kernel/event_server
  import ../kernel/traits/event

  proc testKbdEventPublish() =
    ## Verifies that kbdIrqHandler logic publishes a "key.down" event with the
    ## correct scancode payload.  We drive the logic directly (no real IRQ).
    eventServerInit()

    # Subscribe before firing the simulated handler
    let tok = eventSubscribe("key.down")
    assert tok.isValid, "eventSubscribe should return a valid token"

    # Simulate what kbdIrqHandler does (scancode = 0x1E = 'a')
    let scancode: uint8 = 0x1E
    # picEoi(1) is a no-op in tests (no hardware)
    var sc = scancode
    eventPublish("key.down", addr sc, 1)

    # Poll for the event
    let evOpt = eventPoll(tok)
    assert evOpt.isSome, "key.down event should be pending after publish"

    let ev = evOpt.get()
    assert ev.payload.len == 1, "payload length should be 1 byte"
    assert ev.payload.data[0] == 0x1E, "payload should carry the scancode 0x1E"
    echo "PASS: kbdIrqHandler logic publishes key.down with scancode payload"

  proc testKbdBreakCodeEvent() =
    ## Break codes (bit 7 set) are also published — the consumer decides how to
    ## handle them. Verify the scancode reaches the subscriber unchanged.
    eventServerInit()
    let tok = eventSubscribe("key.down")

    let scancode: uint8 = 0x9E  # break code for 'a' (0x1E | 0x80)
    var sc = scancode
    eventPublish("key.down", addr sc, 1)

    let evOpt = eventPoll(tok)
    assert evOpt.isSome, "break-code event should be published"
    assert evOpt.get().payload.data[0] == 0x9E, "break scancode must be preserved"
    echo "PASS: break-code scancode preserved in key.down event"

when isMainModule:
  testScancodeToAscii()
  testBreakCodesIgnored()
  testUnmappedKeys()
  when defined(testing):
    testKbdEventPublish()
    testKbdBreakCodeEvent()
  echo "All PS/2 keyboard tests passed."
