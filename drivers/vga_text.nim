# SPDX-License-Identifier: GPL-2.0
## VGA Text Mode Driver
##
## 80×25 color text console mapped at physical address 0xB8000.
## Each cell: [character: uint8][attribute: uint8] packed as uint16.
## Attribute byte: low nibble = foreground, high nibble = background color.

import ../kernel/traits/driver

const
  VgaPhysAddr* = 0xB8000'u64
  VgaWidth*    = 80
  VgaHeight*   = 25

type
  VgaColor* = enum
    vgaBlack       = 0
    vgaBlue        = 1
    vgaGreen       = 2
    vgaCyan        = 3
    vgaRed         = 4
    vgaMagenta     = 5
    vgaBrown       = 6
    vgaLightGray   = 7
    vgaDarkGray    = 8
    vgaLightBlue   = 9
    vgaLightGreen  = 10
    vgaLightCyan   = 11
    vgaLightRed    = 12
    vgaLightMagenta = 13
    vgaYellow      = 14
    vgaWhite       = 15

  VgaState* = object
    buf*:  ptr UncheckedArray[uint16]  ## Framebuffer pointer; nil = safe/test mode
    row*:  int
    col*:  int
    attr*: uint8  ## Current color attribute byte

proc vgaAttr*(fg: VgaColor, bg: VgaColor): uint8 {.inline.} =
  ## Pack foreground and background colors into a VGA attribute byte.
  uint8(fg) or (uint8(bg) shl 4)

proc vgaInit*(vga: var VgaState, framebuf: pointer) =
  ## Initialize VGA state. Pass nil for framebuf in unit tests.
  vga.buf  = cast[ptr UncheckedArray[uint16]](framebuf)
  vga.row  = 0
  vga.col  = 0
  vga.attr = vgaAttr(vgaLightGray, vgaBlack)

proc vgaCell(vga: VgaState, c: char): uint16 {.inline.} =
  uint16(vga.attr) shl 8 or uint16(c)

proc vgaScroll(vga: var VgaState) =
  ## Scroll all rows up by one, clear the last row.
  if vga.buf == nil: return
  for r in 1..<VgaHeight:
    for c in 0..<VgaWidth:
      vga.buf[(r - 1) * VgaWidth + c] = vga.buf[r * VgaWidth + c]
  let blank = vgaCell(vga, ' ')
  for c in 0..<VgaWidth:
    vga.buf[(VgaHeight - 1) * VgaWidth + c] = blank

proc vgaAdvanceCursor*(vga: var VgaState) =
  ## Move cursor right one cell, scrolling if we reach the bottom-right corner.
  inc vga.col
  if vga.col >= VgaWidth:
    vga.col = 0
    inc vga.row
    if vga.row >= VgaHeight:
      vgaScroll(vga)
      vga.row = VgaHeight - 1

proc vgaPutChar*(vga: var VgaState, c: char) =
  ## Write one character at the current cursor position and advance.
  case c
  of '\n':
    vga.col = 0
    inc vga.row
    if vga.row >= VgaHeight:
      vgaScroll(vga)
      vga.row = VgaHeight - 1
  of '\r':
    vga.col = 0
  of '\b':
    if vga.col > 0:
      dec vga.col
      if vga.buf != nil:
        vga.buf[vga.row * VgaWidth + vga.col] = vgaCell(vga, ' ')
  else:
    if vga.buf != nil:
      vga.buf[vga.row * VgaWidth + vga.col] = vgaCell(vga, c)
    vgaAdvanceCursor(vga)

proc vgaPutString*(vga: var VgaState, s: cstring) =
  ## Write a null-terminated string.
  var i = 0
  while s[i] != '\0':
    vgaPutChar(vga, s[i])
    inc i

proc vgaClear*(vga: var VgaState) =
  ## Fill the entire screen with spaces using the current attribute.
  if vga.buf == nil: return
  let blank = vgaCell(vga, ' ')
  for i in 0..<(VgaWidth * VgaHeight):
    vga.buf[i] = blank
  vga.row = 0
  vga.col = 0

# Global VGA console instance
var vga*: VgaState

proc vgaDriverInit(): DriverResult {.nimcall.} =
  vgaInit(vga, cast[pointer](VgaPhysAddr))
  vgaClear(vga)
  drOk

proc vgaDriverDeinit(): DriverResult {.nimcall.} =
  drOk

let vgaTextDriver* = DriverVTable(
  name:   "vga_text",
  init:   vgaDriverInit,
  deinit: vgaDriverDeinit,
  irq:    nil
)
