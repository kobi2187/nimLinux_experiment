# SPDX-License-Identifier: GPL-2.0
## Tests for PS/2 mouse packet decoder.
## Pure logic tests — no real hardware needed.

import ../drivers/ps2_mouse

proc testBasicMove() =
  # flags: bit3=1 (always), no overflow, no sign extension, no buttons
  # dx=+10, dy=+5 → after Y inversion: dy=-5
  let pkt = mouseDecodePkt(0x08'u8, 10'u8, 5'u8)
  assert pkt.valid,       "normal packet must be valid"
  assert pkt.dx == 10,    "dx should be +10"
  assert pkt.dy == -5,    "dy should be -5 (Y inverted)"
  assert pkt.buttons == 0, "no buttons pressed"
  echo "PASS: basic move decoding"

proc testNegativeDelta() =
  # rawX=0xF6=246 → cast[int8]=−10; rawY=0xFB=251 → cast[int8]=−5
  # flags: bit3=always1, bit4=X sign, bit5=Y sign (informational only, not used in decode)
  # dy is inverted: -(-5) = +5
  let pkt = mouseDecodePkt(0x38'u8, 0xF6'u8, 0xFB'u8)
  assert pkt.valid,       "negative-delta packet should be valid"
  assert pkt.dx == -10,   "dx should be -10 (0xF6 cast to int8)"
  assert pkt.dy == 5,     "dy should be +5 (Y-inverted -5)"
  echo "PASS: negative delta decoding"

proc testOverflowDiscarded() =
  # X overflow bit set (bit 6)
  let pkt1 = mouseDecodePkt(0x48'u8, 0xFF'u8, 0x00'u8)
  assert not pkt1.valid, "X overflow packet must be discarded"
  # Y overflow bit set (bit 7)
  let pkt2 = mouseDecodePkt(0x88'u8, 0x00'u8, 0xFF'u8)
  assert not pkt2.valid, "Y overflow packet must be discarded"
  echo "PASS: overflow packets discarded"

proc testButtonDecoding() =
  # Left button only
  let left = mouseDecodePkt(0x09'u8, 0'u8, 0'u8)  # bit0=left, bit3=always1
  assert left.valid
  assert (left.buttons and MouseBtnLeft) != 0,   "left button should be set"
  assert (left.buttons and MouseBtnRight) == 0,  "right button should be clear"
  # Right button only
  let right = mouseDecodePkt(0x0A'u8, 0'u8, 0'u8)  # bit1=right, bit3=always1
  assert right.valid
  assert (right.buttons and MouseBtnRight) != 0, "right button should be set"
  assert (right.buttons and MouseBtnLeft) == 0,  "left button should be clear"
  # Both buttons
  let both = mouseDecodePkt(0x0B'u8, 0'u8, 0'u8)
  assert both.valid
  assert (both.buttons and MouseBtnLeft) != 0  and
         (both.buttons and MouseBtnRight) != 0, "both buttons should be set"
  echo "PASS: button decoding"

proc testSyncGuardRejectsOob() =
  ## Reassembler rejects a first byte with bit3=0.
  mouseReset()
  let bad = mouseReassemble(0x00'u8)  # bit3 clear → invalid
  assert not bad.valid, "bad first byte must return invalid packet"
  # Feed a complete valid packet after reset — should succeed
  mouseReset()
  discard mouseReassemble(0x08'u8)
  discard mouseReassemble(5'u8)
  let ok = mouseReassemble(3'u8)
  assert ok.valid, "complete valid packet must succeed after sync guard"
  echo "PASS: sync guard rejects bytes with bit3=0 as first byte"

proc testReassemblerBuildsPacket() =
  ## End-to-end: 3 bytes → valid decoded packet.
  mouseReset()
  let r1 = mouseReassemble(0x08'u8)  # byte 0: bit3=1, no overflow, no sign
  assert not r1.valid, "one byte: packet incomplete"
  let r2 = mouseReassemble(10'u8)    # byte 1: dx=10
  assert not r2.valid, "two bytes: packet incomplete"
  let r3 = mouseReassemble(5'u8)     # byte 2: dy=5 → after inversion: -5
  assert r3.valid,        "three bytes: packet complete"
  assert r3.dx == 10,     "dx should be 10"
  assert r3.dy == -5,     "dy should be -5 (Y inverted)"
  echo "PASS: reassembler accumulates 3-byte packets and resets"

when defined(testing):
  import ../kernel/event_server
  import ../kernel/traits/event

  proc testMouseEventPublish() =
    ## End-to-end: simulate 3 bytes arriving, verify mouse.move event appears.
    ## Uses mouseProcessByte but without kernelFull — events won't fire.
    ## This test is mainly for future use when the test harness compiles with kernelFull.
    eventServerInit()
    let tok = eventSubscribe("mouse.move")
    assert tok.isValid, "subscribe should return valid token"
    echo "PASS: event subscribe path works for mouse.move"

when isMainModule:
  testBasicMove()
  testNegativeDelta()
  testOverflowDiscarded()
  testButtonDecoding()
  testSyncGuardRejectsOob()
  testReassemblerBuildsPacket()
  when defined(testing):
    testMouseEventPublish()
  echo "All PS/2 mouse tests passed."
