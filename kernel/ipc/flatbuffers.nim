# SPDX-License-Identifier: GPL-2.0
## Minimal FlatBuffers builder for NimixOS dispatch messages.
## Stack-allocated, no heap, no dependencies.
## Only supports the DispatchMsg schema — extend as needed.

const FbMaxBufSize* = 512

type
  FbBuilder* = object
    buf*:  array[FbMaxBufSize, byte]
    head*: int   ## current write position from END of buf (FlatBuffers builds back-to-front)

  FbReader* = object
    data*: ptr UncheckedArray[byte]
    len*:  int

# Builder procs
proc fbInit*(b: var FbBuilder) = b.head = FbMaxBufSize

proc fbWriteU8*(b: var FbBuilder; v: uint8) =
  dec b.head; b.buf[b.head] = v

proc fbWriteU32*(b: var FbBuilder; v: uint32) =
  b.head -= 4
  b.buf[b.head+0] = uint8(v and 0xFF)
  b.buf[b.head+1] = uint8((v shr 8) and 0xFF)
  b.buf[b.head+2] = uint8((v shr 16) and 0xFF)
  b.buf[b.head+3] = uint8((v shr 24) and 0xFF)

proc fbWriteI32*(b: var FbBuilder; v: int32) = fbWriteU32(b, cast[uint32](v))

proc fbData*(b: var FbBuilder): (pointer, int) =
  (cast[pointer](addr b.buf[b.head]), FbMaxBufSize - b.head)

# Reader procs
proc fbReadU32*(r: FbReader; offset: int): uint32 =
  if offset + 3 >= r.len: return 0
  uint32(r.data[offset]) or
  (uint32(r.data[offset+1]) shl 8) or
  (uint32(r.data[offset+2]) shl 16) or
  (uint32(r.data[offset+3]) shl 24)

proc fbReadI32*(r: FbReader; offset: int): int32 = cast[int32](fbReadU32(r, offset))

proc fbReadU8*(r: FbReader; offset: int): uint8 =
  if offset >= r.len: return 0
  r.data[offset]
