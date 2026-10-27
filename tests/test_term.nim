# SPDX-License-Identifier: GPL-2.0
## Host tests for term/: VT parser + grid model, and incremental rendering.

import std/[unittest, strutils]
import ../term/vt
import ../term/term_render
import ../gfx/canvas
import ../gfx/bitmap_font
import ../gfx/font_spleen8x16

var t: Term                                   # large: keep it off the stack

proc row(y: int): string = t.rowText(y).strip(leading = false)

suite "vt: text and control characters":
  setup: t.initTerm(10, 4)

  test "text, CR, LF (LF implies CR), backspace, tab":
    t.write("ab\rX\nhi\b!\tZ")
    check row(0) == "Xb"
    check row(1) == "h!      Z"

  test "wrap at the right margin, scroll at the bottom":
    t.write("0123456789ABC")
    check row(0) == "0123456789" and row(1) == "ABC"
    t.write("\n2\n3\n4")
    check row(0) == "ABC" and row(3) == "4"
    check t.scrolled == 1

  test "UTF-8 and malformed bytes":
    t.write("\xC3\xA9\xFF")
    check t.cell(0, 0).cp == 0xE9 and t.cell(1, 0).cp == 0xFFFD

suite "vt: escape sequences":
  setup: t.initTerm(10, 4)

  test "cursor movement and positioning":
    t.write("\e[3;5HX\e[AY\e[2DZ\e[10C!")
    check t.cell(4, 2).cp == uint32('X')
    check t.cell(5, 1).cp == uint32('Y')
    check t.cell(4, 1).cp == uint32('Z')
    check t.curX == 10 and t.curY == 1         # '!' at col 9, deferred wrap

  test "erase line / display":
    t.write("abcdef\e[1;3H\e[K")
    check row(0) == "ab"
    t.write("\n123\e[2J")
    check row(0) == "" and row(1) == ""

  test "SGR colours, bold, reverse, reset":
    t.write("\e[31;1mR\e[7mV\e[0mN\e[94;42mB")
    check t.cell(0, 0).fg == 1 and (t.cell(0, 0).attrs and AttrBold) != 0
    check (t.cell(1, 0).attrs and AttrReverse) != 0
    check t.cell(2, 0).fg == DefaultFg and t.cell(2, 0).attrs == 0
    check t.cell(3, 0).fg == 12 and t.cell(3, 0).bg == 2

  test "private modes and unknown sequences are swallowed":
    t.write("\e[?25lA\e[?25h\e(BB\e[5xC")
    check row(0) == "ABC"

  test "ESC c resets":
    t.write("\e[31mjunk\ecok")
    check row(0) == "ok" and t.cell(0, 0).fg == DefaultFg

suite "render":
  const Cols = 6
  const Rows = 3
  var pix: array[Cols * 8 * Rows * 16, Color]
  var v: TermView

  setup:
    t.initTerm(Cols, Rows)
    v.initView(initCanvas(addr pix[0], Cols * 8, Rows * 16), spleen8x16)

  test "first render paints everything, then only damage":
    let r1 = v.render(t)
    check r1 == Rect(x: 0, y: 0, w: Cols * 8, h: Rows * 16)
    t.write("\e[3;1H")                        # move to the last row
    discard v.render(t)
    t.write("x")
    let r2 = v.render(t)
    check r2 == Rect(x: 0, y: 32, w: Cols * 8, h: 16)

  test "glyph pixels match the font; cursor cell is inverted":
    t.write("A")
    discard v.render(t)
    var cell: array[8 * 16, Color]
    let ref1 = initCanvas(addr cell[0], 8, 16)
    ref1.drawGlyph(spleen8x16, 0, 0, uint32('A'), XtermPalette[DefaultFg], XtermPalette[DefaultBg])
    for y in 0 ..< 16:
      for x in 0 ..< 8:
        check v.canvas.getPixel(x, y) == ref1.getPixel(x, y)
    check v.canvas.getPixel(8, 0) == XtermPalette[DefaultFg]   # cursor at col 1

  test "scrolling moves pixels: result equals a full redraw":
    t.write("one\ntwo\nthree\nfour")
    discard v.render(t)
    var full: array[Cols * 8 * Rows * 16, Color]
    var w2: TermView
    w2.initView(initCanvas(addr full[0], Cols * 8, Rows * 16), spleen8x16)
    for y in 0 ..< Rows: t.dirty[y] = true
    discard w2.render(t)
    check pix == full
