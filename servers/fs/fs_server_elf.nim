# SPDX-License-Identifier: GPL-2.0
## fs_server — userspace ELF scaffold (ring-3 PIE)
##
## Listens on "fs" channel. Receives a path (cstring in msg), calls fsLogicRead,
## sends back FsReadReply as 24 bytes (token:u64 + base:u64 + len:i32 + err:i32).

import fs_logic
import dispatch_wire
import nimix_entry

# ── Kernel ABI (resolved by loader at runtime via stub patching) ──────────────

proc nimixWrite(buf: pointer; len: int) {.importc, cdecl.}
proc nimixExit(code: int) {.importc, cdecl, noreturn.}
proc nimixChanSend(name: cstring; data: pointer; len: int): int {.importc, cdecl.}
proc nimixChanRecv(name: cstring; buf: pointer; len: int): int {.importc, cdecl.}
proc nimixGrantRegion(slot: int; right: uint32): uint64 {.importc, cdecl.}
proc nimixAllocRegion(size: int): pointer {.importc, cdecl.}
proc nimixFreeRegion(p: pointer; size: int) {.importc, cdecl.}

# ── Helpers ───────────────────────────────────────────────────────────────────

proc write(s: cstring) =
  var i = 0
  while s[i] != '\0': inc i
  if i > 0: nimixWrite(cast[pointer](s), i)

# ── Region slot management ────────────────────────────────────────────────────
# Simple slot tracking via address arithmetic.
# RegionBase = 0x400000, RegionSize = 4MB (matches mm/region_allocator.nim).

const RegionBase = 0x400000'u64
const RegionSize = 4 * 1024 * 1024'u64

proc elfAlloc(size: uint64): int {.nimcall.} =
  let p = nimixAllocRegion(int(size))
  if p == nil: return -1
  int((cast[uint64](p) - RegionBase) div RegionSize)

proc elfFree(slot: int) {.nimcall.} =
  let base = RegionBase + uint64(slot) * RegionSize
  nimixFreeRegion(cast[pointer](base), int(RegionSize))

proc elfBase(slot: int): uint64 {.nimcall.} =
  RegionBase + uint64(slot) * RegionSize

proc elfGrant(slot: int; pid: uint32; right: uint32): uint64 {.nimcall.} =
  nimixGrantRegion(slot, right)

proc nimixFsRead(path: cstring; buf: pointer; len: int): int {.importc, cdecl.}

proc elfReadFile(path: cstring; buf: pointer; len: int): (int, int) {.nimcall.} =
  let n = nimixFsRead(path, buf, len)
  if n < 0: return (n, 0)
  (0, n)

# ── Module-level state ────────────────────────────────────────────────────────

var gIface: FsIface

# ── Entry point ───────────────────────────────────────────────────────────────

proc appMain*() {.exportc.} =
  nimixAppInit()   # module init first: --noMain skips it (nimix_entry)
  write("fs_server: starting\n")
  gIface = FsIface(
    readFile:  elfReadFile,
    allocSlot: elfAlloc,
    freeSlot:  elfFree,
    slotBase:  elfBase,
    grantCap:  elfGrant
  )
  write("fs_server: ready on 'fs' channel\n")
  var msgBuf: array[256, char]
  while true:
    let n = nimixChanRecv("fs", addr msgBuf[0], msgBuf.len)
    if n > 0:
      let path = cast[cstring](addr msgBuf[0])
      let reply = fsLogicRead(gIface, path, 0'u32, 4 * 1024 * 1024)
      let repData = encodeReply(WireReply(
        token: reply.token,
        base:  reply.base,
        len:   int32(reply.len),
        err:   int32(reply.err)
      ))
      discard nimixChanSend("fs", cast[pointer](unsafeAddr repData[0]), repData.len)
