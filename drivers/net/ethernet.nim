# SPDX-License-Identifier: GPL-2.0
## Ethernet II frame encode/decode.
##
## Layout: dst(6) | src(6) | ethertype(2) | payload
## ethertype is stored big-endian on the wire.

const EthHdrLen* = 14

type
  EthAddr* = array[6, uint8]

  EthHdr* = object
    dst*, src*: EthAddr
    ethertype*: uint16    # network byte order

proc ethAddrEq*(a, b: EthAddr): bool =
  a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and
  a[3] == b[3] and a[4] == b[4] and a[5] == b[5]

proc writeAddr(dst: ptr UncheckedArray[uint8]; off: int; a: EthAddr) {.inline.} =
  for i in 0..<6: dst[off + i] = a[i]

proc readAddr(src: ptr UncheckedArray[uint8]; off: int): EthAddr =
  for i in 0..<6: result[i] = src[off + i]

proc ethEncode*(buf: pointer; dst, src: EthAddr; ethertype: uint16;
                payloadLen: int): int =
  ## Write Ethernet header into buf. Returns total frame length (hdr+payload).
  let b = cast[ptr UncheckedArray[uint8]](buf)
  writeAddr(b, 0, dst)
  writeAddr(b, 6, src)
  b[12] = uint8(ethertype shr 8)
  b[13] = uint8(ethertype and 0xFF)
  EthHdrLen + payloadLen

proc ethDecode*(buf: pointer; len: int): tuple[hdr: EthHdr; payloadOff: int; ok: bool] =
  ## Parse Ethernet header from buf. payloadOff points past the 14-byte header.
  if len < EthHdrLen:
    return (EthHdr(), 0, false)
  let b = cast[ptr UncheckedArray[uint8]](buf)
  var h: EthHdr
  h.dst       = readAddr(b, 0)
  h.src       = readAddr(b, 6)
  h.ethertype = (uint16(b[12]) shl 8) or uint16(b[13])
  (h, EthHdrLen, true)
