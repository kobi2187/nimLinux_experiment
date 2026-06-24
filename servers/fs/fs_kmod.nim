# SPDX-License-Identifier: GPL-2.0
## FS server — monolithic kernel module variant.
## Has direct access to fatfs and region allocator.

import fs_logic
import ../../fs/fatfs
import ../../mm/region_allocator
import ../../kernel/cap/capability

proc kmodReadFile(path: cstring; buf: pointer; len: int): (int, int) {.nimcall.} =
  if not fsMounted and not fsMount(): return (-1, 0)
  let (res, nbytes) = fsReadInto(path, cast[ptr byte](buf), len)
  if res != fOk: return (-2, 0)
  (0, nbytes)

proc kmodAlloc(size: uint64): int {.nimcall.} =
  let h = regionAlloc(size)
  if not regionValid(h): return -1
  int(h)

proc kmodFree(slot: int) {.nimcall.} =
  regionFree(RegionHandle(slot))

proc kmodBase(slot: int): uint64 {.nimcall.} =
  regionBase(RegionHandle(slot))

proc kmodGrant(slot: int; pid: uint32; right: uint32): uint64 {.nimcall.} =
  let tok = capGrantRegion(slot, pid, CapRight(right))
  uint64(tok)

var gFsState: FsIface

proc fsSrvInit*() =
  gFsState = FsIface(
    readFile:  kmodReadFile,
    allocSlot: kmodAlloc,
    freeSlot:  kmodFree,
    slotBase:  kmodBase,
    grantCap:  kmodGrant
  )

proc fsSrvHandleRead*(path: cstring; callerPid: uint32): FsReadReply =
  fsLogicRead(gFsState, path, callerPid, int(RegionSize))
