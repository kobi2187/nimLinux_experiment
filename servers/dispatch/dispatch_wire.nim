# SPDX-License-Identifier: GPL-2.0
## Dispatch wire protocol — MsgPack encode/decode for dispatch messages.
## Used by dispatch_server_elf and app-side ipc.nim.

import msgpack4nim
import nimixos/wire_types
export wire_types

proc encodeRequest*(op: uint32; pid: uint32): string =
  pack(WireRequest(op: op, pid: pid))

proc decodeRequest*(data: string): WireRequest =
  unpack(data, result)

proc encodeReply*(r: WireReply): string =
  pack(r)

proc decodeReply*(data: string): WireReply =
  unpack(data, result)
