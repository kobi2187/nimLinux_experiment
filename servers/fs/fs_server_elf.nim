# SPDX-License-Identifier: GPL-2.0
## fs_server — PIE ELF server: owns the "fs" channel, serves file reads.
##
## Microkernel shape: the server creates its channel and receives through the
## capability it gets back; clients (regular WASM apps) only send to "fs".
##
## Protocol: request "<reply-topic>\0<path>\0" on "fs". The reply is published
## as an event on <reply-topic>: int32 LE status (bytes read, or < 0 error)
## followed by up to FsInlineMax bytes of file data. Larger reads belong to the
## zero-copy region-cap path (fs_logic) once clients can map regions.

import nimix_common   # write, nimixWrite, nimixExit
import nimix_entry

proc nimixChanCreate(name: cstring): uint64 {.importc, cdecl.}
proc nimixCapRecv(tok: uint64; buf: pointer; len: int): int {.importc, cdecl.}
proc nimixFsRead(path: cstring; buf: pointer; len: int): int {.importc, cdecl.}
proc nimixEventPublish(topic: cstring; data: pointer; len: int) {.importc, cdecl.}
proc nimixYield() {.importc, cdecl.}

const
  FsChannel   = "fs"
  EventMax    = 512             ## kernel event payload limit (MaxPayloadLen)
  FsInlineMax = EventMax - 4    ## data bytes after the int32 status

proc splitRequest(msg: var array[256, char]; n: int): (cstring, cstring) =
  ## "<topic>\0<path>\0" → (topic, path); nil path when malformed.
  msg[min(n, msg.len - 1)] = '\0'
  var i = 0
  while i < n and msg[i] != '\0': inc i
  if i == 0 or i + 1 >= n: return (nil, nil)
  (cast[cstring](addr msg[0]), cast[cstring](addr msg[i + 1]))

proc serve(topic, path: cstring) =
  var reply: array[EventMax, byte]
  let got = nimixFsRead(path, addr reply[4], FsInlineMax)
  let status = int32(got)
  for b in 0 .. 3: reply[b] = byte((status shr (8 * b)) and 0xFF)
  nimixEventPublish(topic, addr reply[0], 4 + max(got, 0))

proc appMain*() {.exportc.} =
  nimixAppInit()   # module init first: --noMain skips it (nimix_entry)
  write("fs_server: starting\n")
  let recvCap = nimixChanCreate(FsChannel)
  if recvCap == 0:
    write("fs_server: channel 'fs' unavailable (already running?) - exiting\n")
    nimixExit(1)
  write("fs_server: ready on 'fs' channel\n")
  var msg: array[256, char]
  while true:
    let n = nimixCapRecv(recvCap, addr msg[0], msg.len - 1)
    if n > 0:
      let (topic, path) = splitRequest(msg, n)
      if not path.isNil: serve(topic, path)
      else: write("fs_server: dropped malformed request\n")
    else:
      nimixYield()   # idle: give the CPU away (interim until block-on-mailbox)
