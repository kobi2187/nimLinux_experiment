# SPDX-License-Identifier: GPL-2.0
## Host tests for gfx/: canvas primitives, clipping, UTF-8, bitmap font.

import std/unittest
import ../gfx/canvas
import ../gfx/bitmap_font
import ../gfx/font_spleen8x16

const W = 32
const H = 20
var buf: array[W * H, Color]

proc canvas(): Canvas =
  for p in buf.mitems: p = 0
  initCanvas(addr buf[0], W, H)

proc count(c: Canvas; color: Color): int =
  for y in 0 ..< c.height:
    for x in 0 ..< c.width:
      if c.getPixel(x, y) == color: inc result

proc decode(s: string): seq[uint32] =
  for cp in utf8Codepoints(s): result.add cp

suite "canvas":
  test "fillRect is clipped to the canvas":
    let c = canvas()
    c.fillRect(Rect(x: -5, y: -5, w: 10, h: 10), 0xFF)
    check c.count(0xFF) == 25
    c.fillRect(Rect(x: W - 2, y: H - 1, w: 99, h: 99), 0xAA)
    check c.count(0xAA) == 2

  test "drawRect outlines, drawLine hits both ends and the diagonal":
    let c = canvas()
    c.drawRect(Rect(x: 1, y: 1, w: 4, h: 3), 7)
    check c.count(7) == 10                   # 4+4+1+1
    c.drawLine(0, 10, 9, 19, 9)
    check c.getPixel(0, 10) == 9 and c.getPixel(9, 19) == 9 and c.getPixel(5, 15) == 9
    c.drawLine(31, 0, -40, 0, 3)            # clipped, no crash
    check c.getPixel(0, 0) == 3

  test "scrollUp moves rows and fills the exposed band":
    let c = canvas()
    c.putPixel(3, 5, 0x11)
    c.scrollUp(c.bounds, 4, 0x22)
    check c.getPixel(3, 1) == 0x11
    check c.getPixel(3, 5) == 0
    check c.count(0x22) == W * 4

  test "union / intersect":
    let a = Rect(x: 0, y: 0, w: 4, h: 4)
    let b = Rect(x: 2, y: 2, w: 4, h: 4)
    check intersect(a, b) == Rect(x: 2, y: 2, w: 2, h: 2)
    check union(a, b) == Rect(x: 0, y: 0, w: 6, h: 6)
    check union(Rect(), b) == b

suite "utf8":
  test "ASCII, 2/3-byte sequences":
    check decode("A\xC3\xA9\xE2\x94\x80") == @[0x41'u32, 0xE9, 0x2500]
  test "malformed and truncated input becomes U+FFFD, then resyncs":
    check decode("\xFFA") == @[Replacement, 0x41'u32]
    check decode("\xC3A") == @[Replacement, 0x41'u32]
    check decode("A\xE2\x94") == @[0x41'u32, Replacement]

suite "bitmap font (Spleen 8x16)":
  test "cell size and coverage":
    check spleen8x16.width == 8 and spleen8x16.height == 16
    for cp in [0x20'u32, 0x41, 0x7E, 0xE9, 0x2500, 0x2588]:
      check spleen8x16.glyphIndex(cp) >= 0
    check spleen8x16.glyphIndex(0x4E2D) == -1             # CJK: not included

  test "missing glyphs fall back to '?'":
    check spleen8x16.glyphRows(0x4E2D) == spleen8x16.glyphRows(uint32('?'))

  test "full block fills its cell, space is empty, 'A' has ink":
    var big: array[8 * 16, Color]
    let c = initCanvas(addr big[0], 8, 16)
    c.drawGlyph(spleen8x16, 0, 0, 0x2588, 1, 0)
    check c.count(1) == 8 * 16
    c.drawGlyph(spleen8x16, 0, 0, uint32(' '), 1, 0)
    check c.count(1) == 0
    c.drawGlyph(spleen8x16, 0, 0, uint32('A'), 1, 0)
    check c.count(1) in 20 .. 80

  test "drawText advances one cell per codepoint":
    let c = canvas()
    check c.drawText(spleen8x16, 0, 0, "a\xC3\xA9", 1, 0) == 16
