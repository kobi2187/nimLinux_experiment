# SPDX-License-Identifier: GPL-2.0
## NimixOS app IPC — MsgPack encode/send/recv helpers.
## Wraps nimixChanSend/nimixChanRecv with typed WireRequest/WireReply.

import msgpack4nim
import wire_types
export wire_types

proc nimixChanSend(name: cstring; data: pointer; len: int): int {.importc, cdecl.}
proc nimixChanRecv(name: cstring; buf: pointer; len: int): int {.importc, cdecl.}

proc ipcRequest*(channel: string; op: uint32; pid: uint32): int =
  ## Send a typed request to a channel. Returns 0=ok, negative=error.
  let encoded = pack(WireRequest(op: op, pid: pid))
  nimixChanSend(channel.cstring, cast[pointer](unsafeAddr encoded[0]), encoded.len)

proc ipcRecvReply*(channel: string): WireReply =
  ## Receive and decode a reply from a channel.
  var buf: array[256, byte]
  let n = nimixChanRecv(channel.cstring, addr buf[0], buf.len)
  if n <= 0: return WireReply(err: int32(n))
  var reply: WireReply
  unpack(cast[string](buf.toOpenArray(0, n-1)), reply)
  reply
