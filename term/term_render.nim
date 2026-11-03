# SPDX-License-Identifier: GPL-2.0
## Draw a Term onto a Canvas with a bitmap font, incrementally: only rows
## the model marked dirty are redrawn, and a scroll moves pixels instead of
## redrawing every row. Returns the damaged pixel rectangle so the caller
## presents just that (e.g. virtioGpuPresentRect).

import vt
import ../gfx/canvas
import ../gfx/bitmap_font

type
  Palette* = array[16, Color]

  TermView* = object
    canvas*: Canvas
    font*: BitmapFont
    originX*, originY*: int
    palette*: Palette
    cursorX, cursorY: int              ## where the cursor was last drawn

const XtermPalette*: Palette = [
  0x1D1F21'u32, 0xCC6666, 0xB5BD68, 0xF0C674, 0x81A2BE, 0xB294BB, 0x8ABEB7, 0xC5C8C6,
  0x666666'u32, 0xD54E53, 0xB9CA4A, 0xE7C547, 0x7AA6DA, 0xC397D8, 0x70C0B1, 0xEAEAEA]

func gridSize*(c: Canvas; f: BitmapFont): tuple[cols, rows: int] =
  (c.width div f.width, c.height div f.height)

proc initView*(v: var TermView; c: Canvas; f: BitmapFont; palette = XtermPalette) =
  v.canvas = c; v.font = f; v.palette = palette
  v.originX = 0; v.originY = 0
  v.cursorX = -1; v.cursorY = -1

func rowRect(v: TermView; t: Term; y: int): Rect =
  Rect(x: v.originX, y: v.originY + y * v.font.height,
       w: t.cols * v.font.width, h: v.font.height)

proc drawCell(v: TermView; t: Term; x, y: int; cursor: bool) =
  let c = t.cell(x, y)
  var fg = v.palette[(c.fg + (if (c.attrs and AttrBold) != 0 and c.fg < 8: 8'u8 else: 0'u8)) and 15]
  var bg = v.palette[c.bg and 15]
  if ((c.attrs and AttrReverse) != 0) xor cursor: swap(fg, bg)
  v.canvas.drawGlyph(v.font, v.originX + x * v.font.width,
                     v.originY + y * v.font.height, c.cp, fg, bg)

proc drawRow(v: TermView; t: Term; y: int) =
  for x in 0 ..< t.cols:
    v.drawCell(t, x, y, cursor = (x == t.curX and y == t.curY))

proc applyScroll(v: var TermView; t: var Term): Rect =
  ## Move already-drawn rows up instead of redrawing them.
  if t.scrolled <= 0: return
  let all = Rect(x: v.originX, y: v.originY, w: t.cols * v.font.width,
                 h: t.rows * v.font.height)
  if t.scrolled >= t.rows:
    for y in 0 ..< t.rows: t.dirty[y] = true
  else:
    v.canvas.scrollUp(all, t.scrolled * v.font.height, v.palette[DefaultBg])
    v.cursorY -= t.scrolled               # the old cursor moved up too
  t.scrolled = 0
  all

proc render*(v: var TermView; t: var Term): Rect =
  ## Bring the canvas up to date with t; returns what changed on screen.
  result = v.applyScroll(t)
  # The cursor cell is drawn inverted: repaint where it was and where it is.
  if v.cursorY in 0 ..< t.rows: t.dirty[v.cursorY] = true
  let cy = min(t.curY, t.rows - 1)
  t.dirty[cy] = true
  for y in 0 ..< t.rows:
    if t.dirty[y]:
      v.drawRow(t, y)
      result = union(result, v.rowRect(t, y))
      t.dirty[y] = false
  v.cursorX = t.curX
  v.cursorY = cy
