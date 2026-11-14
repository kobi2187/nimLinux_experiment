# SPDX-License-Identifier: GPL-2.0
## cat — print a file. A regular (WASM) app: it has no filesystem access of
## its own; it asks fs_server over IPC and gets the reply as an event.
##
## Protocol (fs_server): request "<reply-topic>\0<path>\0" on channel "fs";
## reply on <reply-topic>: int32 LE status (bytes, or < 0 error) + data.

import ../nimix_wasm

const ReplyTopic = "fs.reply.cat"

proc toBytes(parts: varargs[string]): seq[byte] =
  for p in parts:
    for c in p: result.add byte(c)
    result.add 0'u8

nimixWasmMain:
  let path = getArgs()
  if path.len == 0:
    write("usage: cat <file>\n")
    exitApp(1)
  else:
    let tok = subscribe(ReplyTopic)   # subscribe before asking: no lost reply
    chanSend("fs", toBytes(ReplyTopic, path))
    var buf: array[512, byte]
    let n = waitEvent(tok, buf)
    if n < 4:
      write("cat: no reply from fs_server (start it: fs_server)\n")
      exitApp(1)
    else:
      let status = int32(buf[0]) or (int32(buf[1]) shl 8) or
                   (int32(buf[2]) shl 16) or (int32(buf[3]) shl 24)
      if status < 0:
        write("cat: " & path & ": not found\n")
        exitApp(1)
      else:
        writeBytes(addr buf[4], int(status))
        exitApp(0)
