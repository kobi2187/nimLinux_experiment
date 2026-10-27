# SPDX-License-Identifier: GPL-2.0
## Bitmap fonts — fixed-cell glyphs looked up by Unicode codepoint, drawn
## onto a Canvas. Fonts are generated from BDF by tools/bdf2nim.py
## (gfx/font_spleen8x16.nim). Pure Nim, no allocation.

import canvas
import utf8
export utf8

type
  BitmapFont* = object
    width*, height*: int                    ## cell size in pixels
    count*: int                             ## glyphs in the tables
    codepoints*: ptr UncheckedArray[uint32] ## sorted ascending
    rows*: ptr UncheckedArray[uint8]        ## height * rowBytes per glyph

const ReplacementChar* = uint32('?')        ## drawn for codepoints we lack

func rowBytes*(f: BitmapFont): int {.inline.} = (f.width + 7) div 8

func glyphIndex*(f: BitmapFont; cp: uint32): int =
  ## Index of cp's glyph, or -1 (binary search over the sorted table).
  var lo = 0
  var hi = f.count - 1
  while lo <= hi:
    let mid = (lo + hi) div 2
    let v = f.codepoints[mid]
    if v == cp: return mid
    if v < cp: lo = mid + 1 else: hi = mid - 1
  -1

func glyphRows*(f: BitmapFont; cp: uint32): ptr UncheckedArray[uint8] =
  ## Rows of cp's glyph; falls back to '?' (and to nil only for an empty font).
  var i = f.glyphIndex(cp)
  if i < 0: i = f.glyphIndex(ReplacementChar)
  if i < 0: return nil
  cast[ptr UncheckedArray[uint8]](addr f.rows[i * f.height * f.rowBytes])

proc drawGlyph*(c: Canvas; f: BitmapFont; x, y: int; cp: uint32; fg, bg: Color) =
  let rows = f.glyphRows(cp)
  if rows == nil: c.fillRect(Rect(x: x, y: y, w: f.width, h: f.height), bg)
  else: c.blitMono(x, y, f.width, f.height, rows, fg, bg)

proc drawText*(c: Canvas; f: BitmapFont; x, y: int; s: openArray[char];
               fg, bg: Color): int {.discardable.} =
  ## Draw UTF-8 text on one line starting at (x, y); returns the end x.
  var cx = x
  for cp in utf8Codepoints(s):
    c.drawGlyph(f, cx, y, cp, fg, bg)
    cx += f.width
  cx
