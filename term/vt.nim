# SPDX-License-Identifier: GPL-2.0
## Terminal model — a character grid driven by a VT100/ANSI subset.
##
## Parser states follow Paul Williams' DEC parser (ground → escape → CSI);
## only what a shell and line-oriented apps emit is implemented:
##   C0:   BS HT LF VT FF CR (LF implies CR, like a tty with onlcr)
##   ESC c (reset)          other ESC [intermediates] final: ignored
##   CSI   A B C D (move)  H f (position)  J K (erase)  m (SGR colours/attrs)
##   CSI ? … h/l (private modes): ignored
## Text is UTF-8. Fixed-size storage, no allocation: usable by the kernel
## console and by a userspace terminal alike. Rendering lives in term_render.

import ../gfx/utf8

const
  MaxCols* = 240
  MaxRows* = 100
  TabWidth = 8
  MaxParams = 8
  DefaultFg* = 7'u8                    ## palette index (light grey)
  DefaultBg* = 0'u8                    ## palette index (black)
  AttrBold*    = 1'u8
  AttrReverse* = 2'u8

type
  Cell* = object
    cp*: uint32
    fg*, bg*: uint8                    ## palette indices 0..15
    attrs*: uint8

  ParseState = enum psGround, psEscape, psCsi

  Term* = object
    cols*, rows*: int
    cells: array[MaxRows * MaxCols, Cell]
    curX*, curY*: int
    fg, bg, attrs: uint8
    state: ParseState
    params: array[MaxParams, int]
    nparams: int
    privateSeq: bool                   ## CSI ? …
    utf: Utf8Decoder
    dirty*: array[MaxRows, bool]       ## rows changed since the last render
    scrolled*: int                     ## lines scrolled since the last render

func blank(t: Term): Cell {.inline.} =
  Cell(cp: uint32(' '), fg: t.fg, bg: t.bg)

proc cell*(t: Term; x, y: int): Cell {.inline.} = t.cells[y * MaxCols + x]

proc clearRow(t: var Term; y, x0, x1: int) =
  ## Blank columns [x0, x1) of row y.
  for x in max(0, x0) ..< min(t.cols, x1):
    t.cells[y * MaxCols + x] = t.blank
  t.dirty[y] = true

proc resetAttrs(t: var Term) =
  t.fg = DefaultFg; t.bg = DefaultBg; t.attrs = 0

proc initTerm*(t: var Term; cols, rows: int) =
  t.cols = clamp(cols, 1, MaxCols)
  t.rows = clamp(rows, 1, MaxRows)
  t.resetAttrs()
  t.curX = 0; t.curY = 0
  t.state = psGround
  for y in 0 ..< t.rows: t.clearRow(y, 0, t.cols)
  t.scrolled = 0

proc scrollUp(t: var Term) =
  for y in 0 ..< t.rows - 1:
    copyMem(addr t.cells[y * MaxCols], addr t.cells[(y + 1) * MaxCols],
            t.cols * sizeof(Cell))
    t.dirty[y] = t.dirty[y + 1]          # rows move with their content
  t.clearRow(t.rows - 1, 0, t.cols)
  inc t.scrolled

proc lineFeed(t: var Term) =
  t.curX = 0
  if t.curY + 1 < t.rows: inc t.curY
  else: t.scrollUp()

proc putCodepoint(t: var Term; cp: uint32) =
  if t.curX >= t.cols: t.lineFeed()       # deferred wrap
  t.cells[t.curY * MaxCols + t.curX] = Cell(cp: cp, fg: t.fg, bg: t.bg, attrs: t.attrs)
  t.dirty[t.curY] = true
  inc t.curX

proc control(t: var Term; c: char) =
  case c
  of '\b':        (if t.curX > 0: dec t.curX)
  of '\t':        t.curX = min(t.cols - 1, (t.curX div TabWidth + 1) * TabWidth)
  of '\n', '\v', '\f': t.lineFeed()
  of '\r':        t.curX = 0
  of '\e':        t.state = psEscape
  else:           discard                 # BEL, NUL, …

# ── CSI ──────────────────────────────────────────────────────────────────────

func param(t: Term; i, default: int): int {.inline.} =
  if i < t.nparams and t.params[i] > 0: t.params[i] else: default

proc eraseDisplay(t: var Term; mode: int) =
  case mode
  of 0:
    t.clearRow(t.curY, t.curX, t.cols)
    for y in t.curY + 1 ..< t.rows: t.clearRow(y, 0, t.cols)
  of 1:
    for y in 0 ..< t.curY: t.clearRow(y, 0, t.cols)
    t.clearRow(t.curY, 0, t.curX + 1)
  else:
    for y in 0 ..< t.rows: t.clearRow(y, 0, t.cols)

proc eraseLine(t: var Term; mode: int) =
  case mode
  of 0: t.clearRow(t.curY, t.curX, t.cols)
  of 1: t.clearRow(t.curY, 0, t.curX + 1)
  else: t.clearRow(t.curY, 0, t.cols)

proc sgrOne(t: var Term; p: int) =
  case p
  of 0:          t.resetAttrs()
  of 1:          t.attrs = t.attrs or AttrBold
  of 7:          t.attrs = t.attrs or AttrReverse
  of 22:         t.attrs = t.attrs and not AttrBold
  of 27:         t.attrs = t.attrs and not AttrReverse
  of 30 .. 37:   t.fg = uint8(p - 30)
  of 39:         t.fg = DefaultFg
  of 40 .. 47:   t.bg = uint8(p - 40)
  of 49:         t.bg = DefaultBg
  of 90 .. 97:   t.fg = uint8(p - 90 + 8)
  of 100 .. 107: t.bg = uint8(p - 100 + 8)
  else:          discard                  # 256-colour/truecolour: not supported

proc sgr(t: var Term) =
  if t.nparams == 0: t.resetAttrs()
  for i in 0 ..< t.nparams: t.sgrOne(t.params[i])

proc csiDispatch(t: var Term; final: char) =
  if t.privateSeq: return                 # DEC private modes (cursor show/hide…)
  case final
  of 'A': t.curY = max(0, t.curY - t.param(0, 1))
  of 'B': t.curY = min(t.rows - 1, t.curY + t.param(0, 1))
  of 'C': t.curX = min(t.cols - 1, t.curX + t.param(0, 1))
  of 'D': t.curX = max(0, min(t.curX, t.cols - 1) - t.param(0, 1))
  of 'H', 'f':
    t.curY = clamp(t.param(0, 1) - 1, 0, t.rows - 1)
    t.curX = clamp(t.param(1, 1) - 1, 0, t.cols - 1)
  of 'J': t.eraseDisplay(if t.nparams > 0: t.params[0] else: 0)
  of 'K': t.eraseLine(if t.nparams > 0: t.params[0] else: 0)
  of 'm': t.sgr()
  else:   discard

proc csiByte(t: var Term; c: char) =
  case c
  of '0' .. '9':
    if t.nparams == 0: t.nparams = 1
    let i = t.nparams - 1
    t.params[i] = min(t.params[i] * 10 + (ord(c) - ord('0')), 9999)
  of ';':
    if t.nparams == 0: t.nparams = 1   # leading ';' = empty first parameter
    if t.nparams < MaxParams:
      t.params[t.nparams] = 0
      inc t.nparams
  of '?': t.privateSeq = true
  of '@' .. '~':
    t.csiDispatch(c)
    t.state = psGround
  of '\e': t.state = psEscape          # aborted sequence
  else: discard                        # intermediates: ignored

proc escByte(t: var Term; c: char) =
  case c
  of '[':
    t.state = psCsi
    t.nparams = 0; t.params[0] = 0; t.privateSeq = false
  of 'c':
    t.initTerm(t.cols, t.rows)
  of ' ' .. '/':
    discard                              # intermediate (e.g. ESC ( B): wait for final
  else:
    t.state = psGround

# ── input ────────────────────────────────────────────────────────────────────

proc write*(t: var Term; c: char) =
  ## Feed one byte of terminal output.
  case t.state
  of psEscape: t.escByte(c)
  of psCsi:    t.csiByte(c)
  of psGround:
    if uint8(c) < 0x20 or c == '\x7F':
      t.control(c)
      return
    let st = t.utf.feed(c)
    if st.ready: t.putCodepoint(st.cp)
    if st.again: t.write(c)

proc write*(t: var Term; s: openArray[char]) =
  for c in s: t.write(c)

proc rowText*(t: Term; y: int): string =
  ## Row y as text (ASCII; others as '?') — for tests and debugging.
  for x in 0 ..< t.cols:
    let cp = t.cell(x, y).cp
    result.add(if cp < 0x80: char(cp) else: '?')
