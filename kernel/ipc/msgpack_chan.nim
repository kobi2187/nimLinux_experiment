# SPDX-License-Identifier: GPL-2.0
## Minimal MsgPack encoder/decoder for NimixOS control messages.
## Supports: positive fixint (0-127), uint8, uint32, fixstr (≤31 bytes),
##           str8 (≤255 bytes), fixmap (≤15 keys with string keys).
## Self-contained — no stdlib deps, works under --os:any --mm:arc.
##
## TODO: Wire into abiChanSend / abiChanRecv once the dispatcher is fully
## integrated. For now, callers encode with mpBeginMap/mpWriteStr/mpWriteUInt32,
## copy MpBuf.data[0..<pos] into a ServerMsg, and post it themselves.

const
  MP_FIXMAP_BASE = 0x80'u8
  MP_FIXSTR_BASE = 0xA0'u8
  MP_UINT8       = 0xCC'u8
  MP_UINT32      = 0xCE'u8
  MP_STR8        = 0xD9'u8

type
  MpBuf* = object
    data*: array[256, byte]
    pos*:  int

# ── Encoder ───────────────────────────────────────────────────────────────────

proc mpWriteByte*(b: var MpBuf; v: uint8) =
  if b.pos < 256: b.data[b.pos] = v; inc b.pos

proc mpBeginMap*(b: var MpBuf; nkeys: int) =
  ## Emit a fixmap header for up to 15 key/value pairs.
  mpWriteByte(b, MP_FIXMAP_BASE or uint8(nkeys and 0x0F))

proc mpWriteStr*(b: var MpBuf; s: cstring) =
  ## Encode a C string as fixstr (≤31) or str8 (≤255).
  var slen = 0
  while s[slen] != '\0': inc slen
  if slen <= 31:
    mpWriteByte(b, MP_FIXSTR_BASE or uint8(slen))
  else:
    mpWriteByte(b, MP_STR8)
    mpWriteByte(b, uint8(slen))
  for i in 0 ..< slen:
    mpWriteByte(b, uint8(s[i]))

proc mpWriteUInt32*(b: var MpBuf; v: uint32) =
  ## Encode an unsigned integer using the smallest representation.
  if v <= 127:
    mpWriteByte(b, uint8(v))
  elif v <= 255:
    mpWriteByte(b, MP_UINT8)
    mpWriteByte(b, uint8(v))
  else:
    mpWriteByte(b, MP_UINT32)
    mpWriteByte(b, uint8(v shr 24))
    mpWriteByte(b, uint8(v shr 16))
    mpWriteByte(b, uint8(v shr  8))
    mpWriteByte(b, uint8(v))

# ── Decoder ───────────────────────────────────────────────────────────────────

proc mpReadByte*(data: openArray[byte]; pos: var int): uint8 =
  if pos >= data.len: return 0
  result = data[pos]; inc pos

proc mpReadUInt32*(data: openArray[byte]; pos: var int): uint32 =
  ## Decode a positive fixint, uint8, or uint32 value.
  let tag = mpReadByte(data, pos)
  if tag <= 127: return uint32(tag)
  if tag == MP_UINT8: return uint32(mpReadByte(data, pos))
  if tag == MP_UINT32:
    let a = uint32(mpReadByte(data, pos)) shl 24
    let b = uint32(mpReadByte(data, pos)) shl 16
    let c = uint32(mpReadByte(data, pos)) shl  8
    let d = uint32(mpReadByte(data, pos))
    return a or b or c or d
  0

proc mpReadStr*(data: openArray[byte]; pos: var int;
                dst: var array[256, char]): int =
  ## Decode a fixstr or str8 into dst. Returns string length, or -1 on error.
  let tag = mpReadByte(data, pos)
  var slen = 0
  if (tag and 0xE0'u8) == MP_FIXSTR_BASE:
    slen = int(tag and 0x1F)
  elif tag == MP_STR8:
    slen = int(mpReadByte(data, pos))
  else:
    return -1
  let limit = if slen < 255: slen else: 255
  for i in 0 ..< limit:
    dst[i] = char(mpReadByte(data, pos))
  dst[limit] = '\0'
  if slen > limit: pos += slen - limit  # skip overflow bytes
  slen

proc mpSkipStr*(data: openArray[byte]; pos: var int) =
  ## Skip over a fixstr or str8 field.
  let tag = mpReadByte(data, pos)
  var slen = 0
  if (tag and 0xE0'u8) == MP_FIXSTR_BASE: slen = int(tag and 0x1F)
  elif tag == MP_STR8: slen = int(mpReadByte(data, pos))
  pos += slen

proc mpMapLen*(data: openArray[byte]; pos: var int): int =
  ## Read a fixmap header and return number of key/value pairs.
  let tag = mpReadByte(data, pos)
  if (tag and 0xF0'u8) == MP_FIXMAP_BASE:
    return int(tag and 0x0F)
  -1
