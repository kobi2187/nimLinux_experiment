# NimixOS buffers — client side of ipc/buffers for ELF apps.
# Big data moves by handle; mutable memory is never shared (bulk_data.md).
# Errors are negative (-ord(BufError)); handles are per-task values.

const
  ModeMove*  = 0'u32
  ModeLend*  = 1'u32
  ModeShare* = 2'u32
  MaxMsgHandles* = 4

type
  BufMsgHandles* = object       # layout = kernel/buffers/kbuffers.BufMsgHandles
    n*: uint32
    handle*: array[MaxMsgHandles, uint32]
    mode*: array[MaxMsgHandles, uint32]

proc nimixBufCreate*(size: int): int {.importc, cdecl.}
proc nimixBufMap*(h: uint32): pointer {.importc, cdecl.}
proc nimixBufClose*(h: uint32): int {.importc, cdecl.}
proc nimixBufSeal*(h: uint32): int {.importc, cdecl.}
proc nimixBufReturn*(h: uint32): int {.importc, cdecl.}
proc nimixBufMsgSend*(name: cstring; data: pointer; len: int; hs: ptr BufMsgHandles): int {.importc, cdecl.}
proc nimixBufMsgRecv*(tok: uint64; buf: pointer; len: int; hs: ptr BufMsgHandles): int {.importc, cdecl.}

proc sendOne*(chan: cstring; h: uint32; mode: uint32; tag: string): int =
  ## Post `tag` to `chan` with one handle riding along.
  var hs = BufMsgHandles(n: 1)
  hs.handle[0] = h
  hs.mode[0] = mode
  nimixBufMsgSend(chan, unsafeAddr tag[0], tag.len, addr hs)
