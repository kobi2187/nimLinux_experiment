# SPDX-License-Identifier: GPL-2.0
## Draw-command records (docs/proposals/draw_protocol.md §2–3), the subset
## P0 needs. Little-endian, 4-byte aligned:
##   Record = { op: u8, flags: u8, len: u16 } + payload   (len = total bytes)
## An unknown op is skipped by `len`.

import rl_types

type
  Op* = enum
    opBeginFrame = 1, opEndFrame, opCreateTarget, opDestroy, opBeginTarget,
    opEndTarget, opScissorPush, opScissorPop, opClear, opRect, opRectLines,
    opRectRounded, opLine, opCircle, opTriangle, opText, opDrawTexture

  CmdBuf* = object
    data*: seq[byte]
    records*: int

  Reader* = object
    p*: int

proc put[T](b: var CmdBuf; v: T) =
  let n = b.data.len
  b.data.setLen(n + sizeof(T))
  copyMem(addr b.data[n], unsafeAddr v, sizeof(T))

proc beginRec*(b: var CmdBuf; op: Op): int =
  result = b.data.len
  b.put(uint8(op)); b.put(0'u8); b.put(0'u16)   # len patched by endRec
  inc b.records

proc endRec*(b: var CmdBuf; start: int) =
  while (b.data.len and 3) != 0: b.data.add 0'u8
  let len = uint16(b.data.len - start)
  copyMem(addr b.data[start + 2], unsafeAddr len, 2)

template rec*(b: var CmdBuf; op: Op; body: untyped) =
  let st = b.beginRec(op)
  body
  b.endRec(st)

proc putF*(b: var CmdBuf; v: float32) = b.put(v)
proc putI*(b: var CmdBuf; v: int32) = b.put(v)
proc putU*(b: var CmdBuf; v: uint32) = b.put(v)
proc putC*(b: var CmdBuf; c: Color) = b.put(c)
proc putR*(b: var CmdBuf; r: Rectangle) = b.put(r)
proc putV*(b: var CmdBuf; v: Vector2) = b.put(v)
proc putS*(b: var CmdBuf; s: string) =
  b.put(uint16(s.len))
  for ch in s: b.data.add byte(ch)

proc reset*(b: var CmdBuf) =
  b.data.setLen(0); b.records = 0

# ── reading (the decoder validates lengths before trusting a record) ─────────

proc get*[T](b: CmdBuf; r: var Reader): T =
  copyMem(addr result, unsafeAddr b.data[r.p], sizeof(T))
  r.p += sizeof(T)

proc getS*(b: CmdBuf; r: var Reader): string =
  let n = int(get[uint16](b, r))
  result = newString(n)
  if n > 0: copyMem(addr result[0], unsafeAddr b.data[r.p], n)
  r.p += n
