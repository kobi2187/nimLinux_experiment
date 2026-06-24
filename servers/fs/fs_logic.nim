# SPDX-License-Identifier: GPL-2.0
## FS server pure logic — reads files into region slots, mints read caps.
## Injected interface so same logic works in kmod and ELF variants.

type
  FsReadFn*   = proc(path: cstring; buf: pointer; len: int): (int, int) {.nimcall.}
  AllocFn*    = proc(size: uint64): int {.nimcall.}  # returns slot, -1 on fail
  FreeFn*     = proc(slot: int) {.nimcall.}
  BaseFn*     = proc(slot: int): uint64 {.nimcall.}
  GrantFn*    = proc(slot: int; pid: uint32; right: uint32): uint64 {.nimcall.}

  FsIface* = object
    readFile*: FsReadFn
    allocSlot*: AllocFn
    freeSlot*:  FreeFn
    slotBase*:  BaseFn
    grantCap*:  GrantFn

  FsReadReply* = object
    token*:  uint64   ## capMemRead token for the caller
    base*:   uint64   ## region base address
    len*:    int      ## bytes written into region
    err*:    int      ## 0=ok, negative=error code

proc fsLogicRead*(iface: FsIface; path: cstring; callerPid: uint32; maxLen: int): FsReadReply =
  ## Read a file into a fresh region slot, mint capMemRead for callerPid.
  let slot = iface.allocSlot(uint64(maxLen))
  if slot < 0:
    return FsReadReply(err: -1)  # no region slots
  let base = iface.slotBase(slot)
  let (_, nbytes) = iface.readFile(path, cast[pointer](base), maxLen)
  if nbytes <= 0:
    iface.freeSlot(slot)
    return FsReadReply(err: -2)  # file not found or read error
  let tok = iface.grantCap(slot, callerPid, 4'u32)  # 4 = capMemRead
  if tok == 0:
    iface.freeSlot(slot)
    return FsReadReply(err: -3)  # cap mint failed
  FsReadReply(token: tok, base: base, len: nbytes, err: 0)
