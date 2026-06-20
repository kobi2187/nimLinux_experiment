# SPDX-License-Identifier: GPL-2.0
## Tests for VGA text mode driver
## Uses nil framebuffer so no real hardware is touched.

import ../drivers/vga_text

proc testColorEncoding() =
  # Foreground in low nibble, background in high nibble
  let attr = vgaAttr(vgaWhite, vgaBlack)
  assert (attr and 0x0F) == uint8(vgaWhite),  "foreground in low nibble"
  assert (attr shr 4)    == uint8(vgaBlack),  "background in high nibble"

  let attr2 = vgaAttr(vgaBlack, vgaWhite)
  assert (attr2 and 0x0F) == uint8(vgaBlack)
  assert (attr2 shr 4)    == uint8(vgaWhite)
  echo "PASS: VGA color attribute encoding correct"

proc testCursorAdvance() =
  var vga: VgaState
  vgaInit(vga, nil)
  assert vga.col == 0 and vga.row == 0

  # Advance to end of first row
  vga.col = VgaWidth - 1
  vgaAdvanceCursor(vga)
  assert vga.col == 0,   "cursor wraps to col 0 after last column"
  assert vga.row == 1,   "cursor advances to next row"
  echo "PASS: cursor advances and wraps correctly"

proc testNewlineHandling() =
  var vga: VgaState
  vgaInit(vga, nil)
  vga.col = 40
  vgaPutChar(vga, '\n')
  assert vga.col == 0,   "newline resets col to 0"
  assert vga.row == 1,   "newline advances row"
  echo "PASS: newline handling correct"

proc testBackspaceHandling() =
  var vga: VgaState
  vgaInit(vga, nil)
  vga.col = 5
  vgaPutChar(vga, '\b')
  assert vga.col == 4,   "backspace decrements col"

  vga.col = 0
  vgaPutChar(vga, '\b')
  assert vga.col == 0,   "backspace at col 0 does nothing"
  echo "PASS: backspace handling correct"

proc testScrollAtBottom() =
  var vga: VgaState
  vgaInit(vga, nil)
  # Drive cursor to bottom-right
  vga.row = VgaHeight - 1
  vga.col = VgaWidth - 1
  # Advance past end — should stay at last row (scrolled)
  vgaAdvanceCursor(vga)
  assert vga.row == VgaHeight - 1, "row stays at VgaHeight-1 after scroll"
  assert vga.col == 0,              "col resets to 0 after scroll"
  echo "PASS: scroll at bottom of screen"

when isMainModule:
  testColorEncoding()
  testCursorAdvance()
  testNewlineHandling()
  testBackspaceHandling()
  testScrollAtBottom()
  echo "All VGA text driver tests passed."
