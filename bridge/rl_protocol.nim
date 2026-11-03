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
    opRectRounded, opLine, opCircle, opTriangle, opText, opDrawTexture,
    # V7b: one record per raylib call RUI makes (same function server-side,
    # so remote pixels equal direct). Appended: P0's numbers are unchanged.
    opCircleI, opCircleLinesI, opRectI, opRectGradH, opRectGradV, opRectLinesI,
    opRectRoundedLines, opRing, opTexturePro, opTextureV,
    opCreateTexture, opDestroyTexture, opTexFilter, opTexWrap,
    opBlend, opBlendEnd, opBlendFactors, opFlush, opScissorTest, opScissorRaw

  CmdBuf* = object
    data*: seq[byte]
    records*: int
    blobs*: seq[seq[byte]]   ## bulk payloads (texture pixels), referenced by index:
                             ## the loopback stand-in for moved/sealed buffers (BufRef)

  Reader* = object
    p*: int
    limit*: int              ## end of the current record
    bad*: bool               ## a read ran past `limit`: the record is malformed

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
  doAssert b.data.len - start <= 0xFFFF, "record over 64 KB: bulk data goes in a blob"
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
  doAssert s.len <= 0xFFFF
  b.put(uint16(s.len))
  for ch in s: b.data.add byte(ch)

proc putBlob*(b: var CmdBuf; bytes: openArray[byte]) =
  ## Attach a bulk payload; the record carries its index.
  b.put(uint32(b.blobs.len))
  b.blobs.add @bytes

proc reset*(b: var CmdBuf) =
  b.data.setLen(0); b.records = 0; b.blobs.setLen(0)

# ── reading (the decoder validates lengths before trusting a record) ─────────

proc get*[T](b: CmdBuf; r: var Reader): T =
  ## Never reads past the record: a short record reads zeros and marks `bad`.
  if r.bad or r.p + sizeof(T) > r.limit:
    r.bad = true
    return
  copyMem(addr result, unsafeAddr b.data[r.p], sizeof(T))
  r.p += sizeof(T)

proc getS*(b: CmdBuf; r: var Reader): string =
  let n = int(get[uint16](b, r))
  if r.bad or r.p + n > r.limit:
    r.bad = true
    return
  result = newString(n)
  if n > 0: copyMem(addr result[0], unsafeAddr b.data[r.p], n)
  r.p += n
