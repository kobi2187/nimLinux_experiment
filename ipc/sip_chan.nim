# SPDX-License-Identifier: GPL-2.0
## SIP Channel — kernel-mediated WASM app → ELF server IPC
##
## This is the bridge between the WASM host ABI and the server channel system.
## When a WASM app calls env.chan_send("ping", data, len), the WASM runtime
## calls sipChanSend(), which finds the server's registered channel and posts.
##
## Future: sipChanRecv() for server replies back to app (via event server).

import ./server_chan

type
  SipChanResult* = enum
    sipOk       = 0
    sipNoServer    ## No server registered with that name
    sipFull        ## Server channel ring buffer is full
    sipBadLen      ## Payload too large

proc sipChanSend*(serverName: cstring, data: ptr byte, dataLen: int): SipChanResult =
  ## Route a message from a WASM SIP to a named ELF server's mailbox.
  ## Called by the WASM host ABI (env.chan_send).
  var name = ""
  var i = 0
  while serverName[i] != '\0':
    name.add(serverName[i])
    inc i

  let ch = serverChanFind(name)
  if ch == nil:
    return sipNoServer

  if dataLen > ServerMsgMaxLen:
    return sipBadLen

  var msg: ServerMsg
  msg.len = uint16(dataLen)
  if data != nil and dataLen > 0:
    let src = cast[ptr UncheckedArray[byte]](data)
    for i in 0..<dataLen:
      msg.data[i] = src[i]

  if not serverChanPost(ch[], msg):
    return sipFull

  sipOk

proc sipChanSend*(serverName: string, data: ptr byte, dataLen: int): SipChanResult {.inline.} =
  ## String overload for convenience in Nim code.
  sipChanSend(cstring(serverName), data, dataLen)
