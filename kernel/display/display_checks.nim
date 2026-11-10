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
