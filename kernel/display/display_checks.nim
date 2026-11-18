# SPDX-License-Identifier: GPL-2.0
## Display ABI v1 (docs/proposals/display_abi.md): the pure checks on a present
## request. No hardware, no kernel imports: host-tested (tests/test_display_checks.nim).
## All arithmetic is 64-bit so no combination of 32-bit fields can overflow.

const
  BytesPerPixel* = 4
  DisplayFormatB8G8R8X8* = 1'u32       ## the one format v1 has

type
  DisplayError* = enum
    deOk, deBadRect, deBadStride, deOutOfBuffer, deOutOfDisplay

  PresentRect* = object
    stride*: uint32                    ## bytes per row of the source buffer
    sx*, sy*, w*, h*, dx*, dy*: int32

proc bufferBytesNeeded*(r: PresentRect): int64 =
  ## The last byte the copy reads, plus one: rows sy..sy+h-1, each w pixels from sx.
  (int64(r.sy) + int64(r.h) - 1) * int64(r.stride) + (int64(r.sx) + int64(r.w)) * BytesPerPixel

proc checkPresent*(r: PresentRect; bufSize: int64; dispW, dispH: int64): DisplayError =
  if r.w <= 0 or r.h <= 0 or r.sx < 0 or r.sy < 0 or r.dx < 0 or r.dy < 0: return deBadRect
  if r.stride mod BytesPerPixel != 0 or int64(r.stride) < (int64(r.sx) + int64(r.w)) * BytesPerPixel:
    return deBadStride
  if bufferBytesNeeded(r) > bufSize: return deOutOfBuffer
  if int64(r.dx) + int64(r.w) > dispW or int64(r.dy) + int64(r.h) > dispH: return deOutOfDisplay
  deOk

proc inRange*(p, n, lo, hi: uint64): bool =
  ## [p, p+n) inside [lo, hi), with no wrap-around.
  n > 0 and p >= lo and p < hi and n <= hi - p

# ── Display modes (v2) ─────────────────────────────────────────────────────────
# The boot framebuffer is the ceiling: a smaller mode reuses a prefix of the same
# DMA memory (a 2D resource of the new size attached to it), so a mode change
# allocates nothing and cannot fail for lack of memory.

const MaxModes* = 8

type
  DisplayMode* = object
    w*, h*: uint32

const ModeCandidates: array[6, DisplayMode] = [
  DisplayMode(w: 640, h: 480), DisplayMode(w: 800, h: 600), DisplayMode(w: 1024, h: 768),
  DisplayMode(w: 1280, h: 720), DisplayMode(w: 1280, h: 800), DisplayMode(w: 1920, h: 1080)]

proc modeBytes*(m: DisplayMode): uint64 = uint64(m.w) * uint64(m.h) * BytesPerPixel

proc modeList*(boot: DisplayMode; fbBytes: uint64; outp: var array[MaxModes, DisplayMode]): int =
  ## Every mode the kernel accepts, ascending by pixel count: the standard sizes that fit
  ## the boot framebuffer, and the boot mode itself (always, whatever its size).
  var n = 0
  var haveBoot = false
  for c in ModeCandidates:
    if modeBytes(c) <= fbBytes:
      outp[n] = c; inc n
      if c.w == boot.w and c.h == boot.h: haveBoot = true
  if not haveBoot and boot.w > 0 and boot.h > 0 and n < MaxModes:
    outp[n] = boot; inc n
    var i = n - 1                              # keep the list ascending
    while i > 0 and modeBytes(outp[i - 1]) > modeBytes(outp[i]):
      swap(outp[i - 1], outp[i]); dec i
  n

proc modeAllowed*(w, h: uint32; boot: DisplayMode; fbBytes: uint64): bool =
  var ms: array[MaxModes, DisplayMode]
  let n = modeList(boot, fbBytes, ms)
  for i in 0 ..< n:
    if ms[i].w == w and ms[i].h == h: return true
  false
