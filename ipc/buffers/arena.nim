# SPDX-License-Identifier: GPL-2.0
## Buffer arena (buffers B3) — the memory behind buffers.
##
## A window of equal granules. A buffer takes a contiguous run of whole granules, because the granule
## is the unit the enforcement layer grants and revokes: two owners never share one. The kernel uses
## 4 KB granules (a small buffer can have its own owner); host tests use other sizes. The free map is
## a bitmap, one bit per granule, scanned a word at a time.
## Pure: the window's address is just a number here; the kernel maps it.

import std/bitops

const
  MaxBlocks* = 32768              ## granules: 128 MB of 4 KB pages
  Words = MaxBlocks div 64

type
  Arena* = object
    base*: uint64          ## window start (kernel virtual address)
    granule*: int          ## granule size in bytes
    blocks*: int           ## granules in the window (≤ MaxBlocks)
    used: array[Words, uint64]   ## bit i set = granule i allocated

  BlockRun* = object
    first*, count*: int    ## count = 0: no run

func initArena*(base: uint64; granule, blocks: int): Arena =
  assert granule > 0 and blocks in 1 .. MaxBlocks
  Arena(base: base, granule: granule, blocks: blocks)

func blocksFor*(a: Arena; size: int): int =
  ## Whole granules needed for `size` bytes (≥ 1).
  max(1, (size + a.granule - 1) div a.granule)

func isUsed(a: Arena; i: int): bool {.inline.} =
  ((a.used[i shr 6] shr uint64(i and 63)) and 1'u64) != 0

proc setRange(a: var Arena; first, count: int; on: bool) =
  for i in first ..< first + count:
    if on: a.used[i shr 6] = a.used[i shr 6] or (1'u64 shl uint64(i and 63))
    else: a.used[i shr 6] = a.used[i shr 6] and not (1'u64 shl uint64(i and 63))

proc allocRun*(a: var Arena; size: int): BlockRun =
  ## First fit: the lowest contiguous run of free granules that holds `size`.
  let n = a.blocksFor(size)
  if size <= 0 or n > a.blocks: return BlockRun()
  var start = 0
  var len = 0
  var i = 0
  while i < a.blocks:
    if (i and 63) == 0 and a.used[i shr 6] == high(uint64):
      i += 64; start = i; len = 0               # a full word: skip it whole
      continue
    if a.isUsed(i):
      len = 0; start = i + 1
    else:
      inc len
      if len == n:
        a.setRange(start, n, true)
        return BlockRun(first: start, count: n)
    inc i
  BlockRun()

proc freeRun*(a: var Arena; r: BlockRun) =
  if r.count == 0: return
  for i in r.first ..< r.first + r.count:
    assert a.isUsed(i), "arena: freeing blocks that are not allocated"
  a.setRange(r.first, r.count, false)

func runAddr*(a: Arena; r: BlockRun): uint64 =
  a.base + uint64(r.first) * uint64(a.granule)

func runBytes*(a: Arena; r: BlockRun): int = r.count * a.granule

proc freeBlocks*(a: Arena): int =
  var used = 0
  for w in a.used: used += countSetBits(w)
  a.blocks - used
