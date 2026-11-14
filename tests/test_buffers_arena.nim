# SPDX-License-Identifier: GPL-2.0
## buffers B3 — arena of whole blocks (ipc/buffers/arena.nim).

import std/[unittest, random]
import ../ipc/buffers/arena

suite "buffers arena":
  test "sizes round up to whole blocks; addresses follow the run":
    var a = initArena(0x4000_0000'u64, 2 * 1024 * 1024, 64)
    let r = a.allocRun(4 * 1024 * 1024)               # a 1280x800 surface
    check r.count == 2 and r.first == 0
    check a.runAddr(r) == 0x4000_0000'u64
    let s = a.allocRun(1)
    check s.count == 1 and s.first == 2
    check a.runAddr(s) == 0x4000_0000'u64 + 4 * 1024 * 1024
    check a.freeBlocks == 61

  test "first fit reuses freed holes; too-large and empty requests fail":
    var a = initArena(0, 1024, 8)
    let x = a.allocRun(1024)
    let y = a.allocRun(2048)
    discard a.allocRun(1024)
    a.freeRun(y)
    check a.allocRun(2048).first == y.first          # the hole fits exactly
    check a.allocRun(9 * 1024).count == 0
    check a.allocRun(0).count == 0
    a.freeRun(x)
    check a.freeBlocks == 5

  test "full window of 64 blocks (mask edge)":
    var a = initArena(0, 1, 64)
    let r = a.allocRun(64)
    check r.count == 64 and a.freeBlocks == 0
    check a.allocRun(1).count == 0
    a.freeRun(r)
    check a.freeBlocks == 64

  test "random alloc/free never overlaps runs":
    var rng = initRand(7)
    var a = initArena(0, 1, 64)
    var live: seq[BlockRun]
    for i in 0 ..< 20_000:
      if live.len > 0 and rng.rand(1) == 0:
        let k = rng.rand(live.high)
        a.freeRun(live[k]); live.del(k)
      else:
        let r = a.allocRun(1 + rng.rand(7))
        if r.count > 0:
          for o in live:
            check r.first + r.count <= o.first or o.first + o.count <= r.first
          live.add r
    var used = 0
    for r in live: used += r.count
    check a.freeBlocks == 64 - used

  test "4 KB pages: the full 128 MB window, word skipping, holes across word edges":
    var a = initArena(0x4000_0000'u64, 4096, MaxBlocks)
    check MaxBlocks == 32768
    let all = a.allocRun(MaxBlocks * 4096)
    check all.count == MaxBlocks and a.freeBlocks == 0
    check a.allocRun(1).count == 0
    a.freeRun(all)
    check a.freeBlocks == MaxBlocks
    let x = a.allocRun(100 * 4096)                    # crosses a word edge
    let y = a.allocRun(4096)
    check x.first == 0 and y.first == 100
    a.freeRun(x)
    let z = a.allocRun(64 * 4096)                     # a hole of exactly 100 fits 64, then 36 remain
    check z.first == 0
    check a.allocRun(37 * 4096).first == 101          # 36 left in the hole: does not fit there
    check a.runAddr(y) == 0x4000_0000'u64 + 100 * 4096
    check a.runBytes(y) == 4096

  test "random 4 KB alloc/free never overlaps and accounts exactly":
    var rng = initRand(11)
    var a = initArena(0, 4096, MaxBlocks)
    var live: seq[BlockRun]
    for i in 0 ..< 4_000:
      if live.len > 0 and rng.rand(2) == 0:
        let k = rng.rand(live.high)
        a.freeRun(live[k]); live.del(k)
      else:
        let r = a.allocRun(4096 * (1 + rng.rand(600)))
        if r.count > 0:
          for o in live:
            doAssert r.first + r.count <= o.first or o.first + o.count <= r.first
          live.add r
    var used = 0
    for r in live: used += r.count
    check a.freeBlocks == MaxBlocks - used
