# Font rendering via stb_truetype — integrated with raylib for text rendering
# stb_truetype is provided for apps that need direct glyph access

{.pragma: stbTruetype, importc, cdecl, header: "vendor/fonts/stb_truetype.h".}

# stb_truetype C function signatures (minimal subset for glyph metrics/rasterization)
type
  StbTtFontinfo* {.importc: "stbtt_fontinfo".} = object
    data*: pointer
    offset*: cint
    # (actual struct has many more fields, opaque to us)

proc stbtt_InitFont*(info: var StbTtFontinfo; data: ptr UncheckedArray[uint8]; offset: cint): cint {.stbTruetype.}
proc stbtt_ScaleForPixelHeight*(info: var StbTtFontinfo; pixels: cfloat): cfloat {.stbTruetype.}
proc stbtt_GetCodepointBitmapBox*(info: var StbTtFontinfo; codepoint: cint; scale_x, scale_y: cfloat;
                                   ix0, iy0, ix1, iy1: var cint) {.stbTruetype.}
proc stbtt_MakeCodepointBitmap*(info: var StbTtFontinfo; output: ptr UncheckedArray[uint8];
                                 out_w, out_h, out_stride: cint;
                                 scale_x, scale_y: cfloat; codepoint: cint) {.stbTruetype.}
proc stbtt_GetCodepointHMetrics*(info: var StbTtFontinfo; codepoint: cint;
                                  advanceWidth, leftSideBearing: var cint) {.stbTruetype.}

type
  Font* = object
    fontData*: seq[uint8]  # owned copy of TTF bytes
    info*: StbTtFontinfo
    scale*: cfloat
    heightPixels*: int

proc loadFont*(data: ptr UncheckedArray[uint8]; dataLen: int; heightPixels: int): Font =
  ## Load and initialize a TrueType font at a specific height
  var font: Font
  font.heightPixels = heightPixels
  font.fontData = newSeq[uint8](dataLen)
  copyMem(font.fontData[0].addr, data, dataLen)

  let offset = stbtt_InitFont(font.info, cast[ptr UncheckedArray[uint8]](font.fontData[0].addr), 0)
  if offset == 0:
    return font  # failed init

  font.scale = stbtt_ScaleForPixelHeight(font.info, float32(heightPixels))
  return font

proc getGlyphBitmap*(font: var Font; codepoint: uint32): tuple[bitmap: seq[uint8], width: int, height: int, offsetX: int, offsetY: int] =
  ## Rasterize a single glyph to a bitmap (for advanced text rendering)
  var x0, y0, x1, y1: cint
  stbtt_GetCodepointBitmapBox(font.info, cint(codepoint), font.scale, font.scale, x0, y0, x1, y1)

  let w = int(x1 - x0)
  let h = int(y1 - y0)

  if w <= 0 or h <= 0:
    return (newSeq[uint8](), 0, 0, 0, 0)

  var bitmap = newSeq[uint8](w * h)
  stbtt_MakeCodepointBitmap(font.info, cast[ptr UncheckedArray[uint8]](bitmap[0].addr),
                             cint(w), cint(h), cint(w), font.scale, font.scale, cint(codepoint))

  return (bitmap, w, h, int(x0), int(y0))

proc getGlyphAdvance*(font: var Font; codepoint: uint32): int =
  ## Get the advance width for a glyph
  var advanceWidth, lsb: cint
  stbtt_GetCodepointHMetrics(font.info, cint(codepoint), advanceWidth, lsb)
  return int(float(advanceWidth) * font.scale)
