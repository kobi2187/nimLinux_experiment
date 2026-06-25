# SPDX-License-Identifier: GPL-2.0
## UDP header encode/decode.
##
## 8-byte fixed header: srcPort | dstPort | length | checksum
## Checksum field is left zero (optional per RFC 768 for IPv4).

const UdpHdrLen* = 8

type
  UdpHdr* = object
    srcPort*:  uint16
    dstPort*:  uint16
    length*:   uint16
    checksum*: uint16

proc writeU16Be(dst: ptr UncheckedArray[uint8]; off: int; v: uint16) {.inline.} =
  dst[off]   = uint8(v shr 8)
  dst[off+1] = uint8(v and 0xFF)

proc readU16Be(src: ptr UncheckedArray[uint8]; off: int): uint16 {.inline.} =
  (uint16(src[off]) shl 8) or uint16(src[off+1])

proc udpEncode*(buf: pointer; srcPort, dstPort: uint16;
                payload: pointer; payloadLen: int): int =
  ## Write UDP header then copy payload. Returns total length (hdr+payload).
  let b   = cast[ptr UncheckedArray[uint8]](buf)
  let tot = uint16(UdpHdrLen + payloadLen)
  writeU16Be(b, 0, srcPort)
  writeU16Be(b, 2, dstPort)
  writeU16Be(b, 4, tot)
  writeU16Be(b, 6, 0)     # checksum=0 (optional)
  let src = cast[ptr UncheckedArray[uint8]](payload)
  for i in 0..<payloadLen:
    b[UdpHdrLen + i] = src[i]
  int(tot)

proc udpDecode*(buf: pointer; len: int): tuple[hdr: UdpHdr; payloadOff: int; ok: bool] =
  ## Parse a UDP header. payloadOff points past the 8-byte header.
  if len < UdpHdrLen:
    return (UdpHdr(), 0, false)
  let b = cast[ptr UncheckedArray[uint8]](buf)
  var h: UdpHdr
  h.srcPort  = readU16Be(b, 0)
  h.dstPort  = readU16Be(b, 2)
  h.length   = readU16Be(b, 4)
  h.checksum = readU16Be(b, 6)
  (h, UdpHdrLen, true)
