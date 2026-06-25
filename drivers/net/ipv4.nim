# SPDX-License-Identifier: GPL-2.0
## IPv4 header encode/decode and checksum.
##
## Only the fixed 20-byte header (IHL=5, no options).
## All multi-byte fields are in network byte order on the wire.

const IpHdrLen* = 20

type
  IpAddr* = uint32   # network byte order

  IpHdr* = object
    version_ihl*: uint8
    tos*:         uint8
    totalLen*:    uint16
    id*:          uint16
    fragOff*:     uint16
    ttl*:         uint8
    protocol*:    uint8
    checksum*:    uint16
    src*:         IpAddr
    dst*:         IpAddr

proc hton32(v: uint32): uint32 {.inline.} =
  ((v and 0xFF'u32) shl 24) or ((v and 0xFF00'u32) shl 8) or
  ((v shr 8) and 0xFF00'u32) or (v shr 24)

proc ipAddr*(a, b, c, d: uint8): IpAddr =
  ## Build a network-byte-order IpAddr from four octets (a.b.c.d).
  hton32((uint32(a) shl 24) or (uint32(b) shl 16) or
         (uint32(c) shl 8)  or  uint32(d))

proc ipChecksum*(buf: pointer; len: int): uint16 =
  ## Internet checksum (RFC 1071) over `len` bytes.
  let b = cast[ptr UncheckedArray[uint8]](buf)
  var sum: uint32 = 0
  var i = 0
  while i + 1 < len:
    sum += (uint32(b[i]) shl 8) or uint32(b[i+1])
    i += 2
  if (len and 1) != 0:
    sum += uint32(b[len-1]) shl 8
  while (sum shr 16) != 0:
    sum = (sum and 0xFFFF'u32) + (sum shr 16)
  uint16(not sum)

proc writeU16Be(dst: ptr UncheckedArray[uint8]; off: int; v: uint16) {.inline.} =
  dst[off]   = uint8(v shr 8)
  dst[off+1] = uint8(v and 0xFF)

proc writeU32Be(dst: ptr UncheckedArray[uint8]; off: int; v: uint32) {.inline.} =
  dst[off]   = uint8(v shr 24)
  dst[off+1] = uint8((v shr 16) and 0xFF)
  dst[off+2] = uint8((v shr 8) and 0xFF)
  dst[off+3] = uint8(v and 0xFF)

proc readU16Be(src: ptr UncheckedArray[uint8]; off: int): uint16 {.inline.} =
  (uint16(src[off]) shl 8) or uint16(src[off+1])

proc readU32Be(src: ptr UncheckedArray[uint8]; off: int): uint32 {.inline.} =
  (uint32(src[off]) shl 24) or (uint32(src[off+1]) shl 16) or
  (uint32(src[off+2]) shl 8) or uint32(src[off+3])

proc ipEncode*(buf: pointer; src, dst: IpAddr; protocol: uint8;
               payloadLen: int): int =
  ## Write a 20-byte IPv4 header. Returns total IP packet length (hdr+payload).
  let b = cast[ptr UncheckedArray[uint8]](buf)
  let totalLen = uint16(IpHdrLen + payloadLen)
  b[0] = 0x45'u8              # version=4, IHL=5
  b[1] = 0                    # DSCP/ECN
  writeU16Be(b, 2, totalLen)
  writeU16Be(b, 4, 0)         # id=0
  writeU16Be(b, 6, 0)         # flags+fragOff=0
  b[8]  = 64                  # TTL=64
  b[9]  = protocol
  writeU16Be(b, 10, 0)        # checksum placeholder
  writeU32Be(b, 12, src)
  writeU32Be(b, 16, dst)
  # compute and patch checksum
  let csum = ipChecksum(buf, IpHdrLen)
  writeU16Be(b, 10, csum)
  IpHdrLen + payloadLen

proc ipDecode*(buf: pointer; len: int): tuple[hdr: IpHdr; payloadOff: int; ok: bool] =
  ## Parse a 20-byte IPv4 header. payloadOff points past the header.
  if len < IpHdrLen:
    return (IpHdr(), 0, false)
  let b = cast[ptr UncheckedArray[uint8]](buf)
  if (b[0] shr 4) != 4:      # version must be 4
    return (IpHdr(), 0, false)
  var h: IpHdr
  h.version_ihl = b[0]
  h.tos         = b[1]
  h.totalLen    = readU16Be(b, 2)
  h.id          = readU16Be(b, 4)
  h.fragOff     = readU16Be(b, 6)
  h.ttl         = b[8]
  h.protocol    = b[9]
  h.checksum    = readU16Be(b, 10)
  h.src         = readU32Be(b, 12)
  h.dst         = readU32Be(b, 16)
  let ihl = int(h.version_ihl and 0x0F) * 4
  (h, ihl, true)
