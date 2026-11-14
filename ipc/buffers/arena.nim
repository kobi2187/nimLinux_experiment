# SPDX-License-Identifier: GPL-2.0
## Buffer arena (buffers B3, Stage A) — the memory behind buffers.
##
## A window of up to 64 equal blocks (Stage A: 64 × 2 MB = 128 MB). A buffer
## takes a contiguous run of whole blocks, because a block is the unit the
## enforcement layer grants and revokes: two owners never share one. The free
## map is a single 64-bit word, so allocation is a few bit operations.
## Pure: the window's address is just a number here; the kernel maps it.

const MaxBlocks* = 64

type
  Arena* = object
    base*: uint64          ## window start (kernel virtual address)
    granule*: int          ## block size in bytes (BlockSize in the kernel)
    blocks*: int           ## blocks in the window (≤ MaxBlocks)
    used: uint64           ## bit i set = block i allocated

  BlockRun* = object
    first*, count*: int    ## count = 0: no run

func initArena*(base: uint64; granule, blocks: int): Arena =
  assert granule > 0 and blocks in 1 .. MaxBlocks
  Arena(base: base, granule: granule, blocks: blocks)

func blocksFor*(a: Arena; size: int): int =
  ## Whole blocks needed for `size` bytes (≥ 1).
  max(1, (size + a.granule - 1) div a.granule)

func runMask(first, count: int): uint64 {.inline.} =
  (if count >= 64: not 0'u64 else: (1'u64 shl count) - 1) shl first

proc allocRun*(a: var Arena; size: int): BlockRun =
  ## First fit: the lowest contiguous run of free blocks that holds `size`.
  let n = a.blocksFor(size)
  if size <= 0 or n > a.blocks: return BlockRun()
  for first in 0 .. a.blocks - n:
    let m = runMask(first, n)
    if (a.used and m) == 0:
      a.used = a.used or m
      return BlockRun(first: first, count: n)
  BlockRun()

proc freeRun*(a: var Arena; r: BlockRun) =
  if r.count == 0: return
  let m = runMask(r.first, r.count)
  assert (a.used and m) == m, "arena: freeing blocks that are not allocated"
  a.used = a.used and not m

func runAddr*(a: Arena; r: BlockRun): uint64 =
  a.base + uint64(r.first) * uint64(a.granule)

func runBytes*(a: Arena; r: BlockRun): int = r.count * a.granule

proc freeBlocks*(a: Arena): int =
  for i in 0 ..< a.blocks:
    if (a.used and (1'u64 shl i)) == 0: inc result
