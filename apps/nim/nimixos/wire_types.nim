# SPDX-License-Identifier: GPL-2.0
## Shared wire types for NimixOS IPC messages (dispatch + fs).
## Imported by both servers/dispatch/dispatch_wire.nim and apps/nim/nimixos/ipc.nim.

type
  WireRequest* = object
    op*:  uint32
    pid*: uint32

  WireReply* = object
    token*: uint64
    base*:  uint64
    len*:   int32
    err*:   int32
