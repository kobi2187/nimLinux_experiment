# SPDX-License-Identifier: GPL-2.0
## Canvas — a clipped 32-bit (0x00RRGGBB) pixel target over any memory:
## the virtio-gpu framebuffer, a window buffer in an app region, or a host
## test array. Pure Nim, no allocation, no kernel imports (oskit library).

type
  Color* = uint32                       ## 0x00RRGGBB (virtio-gpu B8G8R8X8 in memory)

  Canvas* = object
    pixels*: ptr UncheckedArray[Color]
    width*, height*: int
    stride*: int                        ## pixels per row (>= width)

  Rect* = object
    x*, y*, w*, h*: int

func rgb*(r, g, b: uint8): Color {.inline.} =
  (Color(r) shl 16) or (Color(g) shl 8) or Color(b)

func initCanvas*(pixels: pointer; width, height: int; stride = 0): Canvas =
  Canvas(pixels: cast[ptr UncheckedArray[Color]](pixels), width: width,
         height: height, stride: if stride > 0: stride else: width)

func isEmpty*(r: Rect): bool {.inline.} = r.w <= 0 or r.h <= 0

func intersect*(a, b: Rect): Rect =
  let x0 = max(a.x, b.x)
  let y0 = max(a.y, b.y)
  let x1 = min(a.x + a.w, b.x + b.w)
  let y1 = min(a.y + a.h, b.y + b.h)
  Rect(x: x0, y: y0, w: max(0, x1 - x0), h: max(0, y1 - y0))

func union*(a, b: Rect): Rect =
  ## Bounding box of both (an empty side is ignored).
  if a.isEmpty: return b
  if b.isEmpty: return a
  let x0 = min(a.x, b.x)
  let y0 = min(a.y, b.y)
  Rect(x: x0, y: y0, w: max(a.x + a.w, b.x + b.w) - x0,
       h: max(a.y + a.h, b.y + b.h) - y0)

func bounds*(c: Canvas): Rect {.inline.} = Rect(x: 0, y: 0, w: c.width, h: c.height)

proc getPixel*(c: Canvas; x, y: int): Color {.inline.} =
  if x < 0 or y < 0 or x >= c.width or y >= c.height: return 0
  c.pixels[y * c.stride + x]

proc putPixel*(c: Canvas; x, y: int; color: Color) {.inline.} =
  if x < 0 or y < 0 or x >= c.width or y >= c.height: return
  c.pixels[y * c.stride + x] = color

proc fillRect*(c: Canvas; r: Rect; color: Color) =
  let k = intersect(r, c.bounds)
  for y in k.y ..< k.y + k.h:
    let row = y * c.stride
    for x in k.x ..< k.x + k.w:
      c.pixels[row + x] = color

proc clear*(c: Canvas; color: Color) = c.fillRect(c.bounds, color)

proc hline*(c: Canvas; x, y, w: int; color: Color) =
  c.fillRect(Rect(x: x, y: y, w: w, h: 1), color)

proc vline*(c: Canvas; x, y, h: int; color: Color) =
  c.fillRect(Rect(x: x, y: y, w: 1, h: h), color)

proc drawRect*(c: Canvas; r: Rect; color: Color) =
  ## 1-pixel outline.
  if r.isEmpty: return
  c.hline(r.x, r.y, r.w, color)
  c.hline(r.x, r.y + r.h - 1, r.w, color)
  c.vline(r.x, r.y, r.h, color)
  c.vline(r.x + r.w - 1, r.y, r.h, color)

proc drawLine*(c: Canvas; x0, y0, x1, y1: int; color: Color) =
  ## Bresenham, any octant; clipped per pixel.
  let dx = abs(x1 - x0)
  let dy = -abs(y1 - y0)
  let sx = if x0 < x1: 1 else: -1
  let sy = if y0 < y1: 1 else: -1
  var err = dx + dy
  var x = x0
  var y = y0
  while true:
    c.putPixel(x, y, color)
    if x == x1 and y == y1: break
    let e2 = 2 * err
    if e2 >= dy: err += dy; x += sx
    if e2 <= dx: err += dx; y += sy

proc blitMono*(c: Canvas; x, y, w, h: int; rows: ptr UncheckedArray[uint8];
               fg, bg: Color; transparentBg = false) =
  ## Draw a 1-bit bitmap (rows of (w+7) div 8 bytes, MSB = leftmost pixel):
  ## set bits in fg, clear bits in bg (or left untouched if transparentBg).
  let rowBytes = (w + 7) div 8
  for gy in 0 ..< h:
    let py = y + gy
    if py < 0 or py >= c.height: continue
    for gx in 0 ..< w:
      let px = x + gx
      if px < 0 or px >= c.width: continue
      let bit = (rows[gy * rowBytes + gx div 8] shr (7 - gx mod 8)) and 1
      if bit == 1: c.pixels[py * c.stride + px] = fg
      elif not transparentBg: c.pixels[py * c.stride + px] = bg

proc scrollUp*(c: Canvas; r: Rect; dy: int; fill: Color) =
  ## Move the pixels of r up by dy rows; the exposed bottom rows get fill.
  let k = intersect(r, c.bounds)
  if k.isEmpty or dy <= 0: return
  if dy >= k.h:
    c.fillRect(k, fill); return
  for y in k.y ..< k.y + k.h - dy:
    copyMem(addr c.pixels[y * c.stride + k.x],
            addr c.pixels[(y + dy) * c.stride + k.x], k.w * sizeof(Color))
  c.fillRect(Rect(x: k.x, y: k.y + k.h - dy, w: k.w, h: dy), fill)
