# SPDX-License-Identifier: GPL-2.0
## Dispatch wire protocol — MsgPack encode/decode for dispatch messages.
## Used by dispatch_server_elf and app-side ipc.nim.

import msgpack4nim
import nimixos/wire_types
export wire_types

proc encodeRequest*(op: uint32; pid: uint32): string =
  pack(WireRequest(op: op, pid: pid))

proc decodeRequest*(data: string): WireRequest =
  ## Trusted input only: msgpack4nim asserts on shape mismatch, which is a
  ## fatal Defect under --panics:on. Untrusted bytes go through tryDecodeRequest.
  unpack(data, result)

proc readUint32(data: string; pos: var int; v: var uint32): bool =
  ## One MsgPack unsigned int (positive fixint / uint8 / uint16 / uint32).
  if pos >= data.len: return false
  let tag = uint8(data[pos])
  var width = 0
  case tag
  of 0x00'u8 .. 0x7f'u8: v = uint32(tag); inc pos; return true
  of 0xcc'u8: width = 1
  of 0xcd'u8: width = 2
  of 0xce'u8: width = 4
  else: return false
  if pos + width >= data.len: return false
  v = 0
  for i in 1 .. width:
    v = (v shl 8) or uint32(uint8(data[pos + i]))
  pos += width + 1
  true

proc tryDecodeRequest*(data: string; req: var WireRequest): bool =
  ## Strict, non-raising decode of an untrusted WireRequest ([op, pid] as a
  ## 2-element array of uints). False on any deviation, including trailing bytes.
  if data.len < 3 or uint8(data[0]) != 0x92'u8: return false
  var pos = 1
  readUint32(data, pos, req.op) and readUint32(data, pos, req.pid) and
    pos == data.len

proc encodeReply*(r: WireReply): string =
  pack(r)

proc decodeReply*(data: string): WireReply =
  unpack(data, result)
