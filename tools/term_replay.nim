# SPDX-License-Identifier: GPL-2.0
## term_replay — render a console byte stream exactly as the framebuffer
## console would, on the host, to a PPM. tests/qemu_devices.py compares it
## pixel-for-pixel with a QMP screendump of the virtio-gpu head.
##
##   term_replay <bytes-file> <width> <height> <out.ppm>

import std/[os, strutils]
import ../term/vt
import ../term/term_render
import ../gfx/canvas
import ../gfx/font_spleen8x16

var t: Term

proc main() =
  let data = readFile(paramStr(1))
  let w = parseInt(paramStr(2))
  let h = parseInt(paramStr(3))
  var pixels = newSeq[Color](w * h)
  let c = initCanvas(addr pixels[0], w, h)
  let (cols, rows) = gridSize(c, spleen8x16)
  t.initTerm(cols, rows)
  var v: TermView
  v.initView(c, spleen8x16)
  c.clear(XtermPalette[DefaultBg])
  for ch in data: t.write(ch)
  for y in 0 ..< t.rows: t.dirty[y] = true
  discard v.render(t)
  var ppm = "P6\n" & $w & " " & $h & "\n255\n"
  for p in pixels:
    ppm.add char((p shr 16) and 0xFF)
    ppm.add char((p shr 8) and 0xFF)
    ppm.add char(p and 0xFF)
  writeFile(paramStr(4), ppm)

main()
