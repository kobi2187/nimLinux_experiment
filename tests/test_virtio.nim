# SPDX-License-Identifier: GPL-2.0
## Virtio driver unit tests — host-side, no hardware required.
##
## Covers: VirtioNetHdr layout, Ethernet encode/decode,
##         IPv4 checksum, UDP encode/decode, virtqueue ring layout.

import ../drivers/net/ethernet
import ../drivers/net/ipv4
import ../drivers/net/udp
import ../drivers/virtio/virtqueue

# ── VirtioNetHdr size ────────────────────────────────────────────────────────

type VirtioNetHdrTest {.packed.} = object
  flags*:      uint8
  gsoType*:    uint8
  hdrLen*:     uint16
  gsoSize*:    uint16
  csumStart*:  uint16
  csumOffset*: uint16
  numBuffers*: uint16

proc testNetHdrSize() =
  assert sizeof(VirtioNetHdrTest) == 12,
    "VirtioNetHdr must be exactly 12 bytes"
  echo "PASS: VirtioNetHdr size == 12"

# ── Ethernet encode/decode round-trip ────────────────────────────────────────

proc testEthernetRoundTrip() =
  var frameBuf: array[128, uint8]
  let dst: EthAddr = [0xDE'u8, 0xAD, 0xBE, 0xEF, 0x00, 0x01]
  let src: EthAddr = [0x52'u8, 0x54, 0x00, 0x12, 0x34, 0x56]
  let etype = 0x0800'u16  # IPv4

  let total = ethEncode(addr frameBuf[0], dst, src, etype, 0)
  assert total == EthHdrLen, "ethEncode returns hdr+payload length"

  let (hdr, payOff, ok) = ethDecode(addr frameBuf[0], total)
  assert ok, "ethDecode must succeed on valid frame"
  assert payOff == EthHdrLen, "payload offset must be 14"
  assert ethAddrEq(hdr.dst, dst), "destination MAC round-trips"
  assert ethAddrEq(hdr.src, src), "source MAC round-trips"
  assert hdr.ethertype == etype, "ethertype round-trips"

  # Known-byte check: byte 12-13 must be 0x08, 0x00
  assert frameBuf[12] == 0x08'u8, "ethertype high byte on wire"
  assert frameBuf[13] == 0x00'u8, "ethertype low byte on wire"
  echo "PASS: Ethernet encode/decode round-trip"

proc testEthernetDecodeShort() =
  var buf: array[10, uint8]
  let (_, _, ok) = ethDecode(addr buf[0], buf.len)
  assert not ok, "ethDecode on short buffer must fail"
  echo "PASS: Ethernet decode rejects short buffer"

# ── IPv4 checksum ────────────────────────────────────────────────────────────

proc testIpChecksum() =
  # Standard example from RFC 1071: known 20-byte IP header
  var hdr: array[20, uint8] = [
    0x45'u8, 0x00, 0x00, 0x3C,
    0x1C'u8, 0x46, 0x40, 0x00,
    0x40'u8, 0x06, 0x00, 0x00,   # checksum field = 0 (placeholder)
    0xAC'u8, 0x10, 0x0A, 0x63,   # src 172.16.10.99
    0xAC'u8, 0x10, 0x0A, 0x0C    # dst 172.16.10.12
  ]
  let csum = ipChecksum(addr hdr[0], 20)
  # Patch checksum back, verify it now passes (re-computed must == 0)
  hdr[10] = uint8(csum shr 8)
  hdr[11] = uint8(csum and 0xFF)
  let verify = ipChecksum(addr hdr[0], 20)
  assert verify == 0, "checksum over header with embedded csum must be 0"
  echo "PASS: IPv4 checksum"

proc testIpEncodeDecodeRoundTrip() =
  var pkt: array[64, uint8]
  let srcIp = ipAddr(192, 168, 1, 1)
  let dstIp = ipAddr(192, 168, 1, 2)
  let total = ipEncode(addr pkt[0], srcIp, dstIp, 17, 8)
  assert total == IpHdrLen + 8, "ipEncode returns correct total length"

  let (hdr, payOff, ok) = ipDecode(addr pkt[0], total)
  assert ok, "ipDecode must succeed"
  assert payOff == IpHdrLen, "payload offset must be 20"
  assert hdr.src == srcIp, "source IP round-trips"
  assert hdr.dst == dstIp, "dest IP round-trips"
  assert hdr.protocol == 17, "protocol round-trips"

  # Verify embedded checksum is valid
  let verify = ipChecksum(addr pkt[0], IpHdrLen)
  assert verify == 0, "header checksum must be valid"
  echo "PASS: IPv4 encode/decode round-trip"

# ── UDP encode/decode round-trip ─────────────────────────────────────────────

proc testUdpRoundTrip() =
  var buf: array[64, uint8]
  var payload: array[4, uint8] = [0xDE'u8, 0xAD, 0xBE, 0xEF]
  let n = udpEncode(addr buf[0], 12345'u16, 53'u16, addr payload[0], 4)
  assert n == UdpHdrLen + 4, "udpEncode returns hdr+payload length"

  let (hdr, payOff, ok) = udpDecode(addr buf[0], n)
  assert ok, "udpDecode must succeed"
  assert payOff == UdpHdrLen, "payload offset must be 8"
  assert hdr.srcPort == 12345'u16, "srcPort round-trips"
  assert hdr.dstPort == 53'u16,    "dstPort round-trips"
  assert hdr.length  == uint16(UdpHdrLen + 4), "length field round-trips"

  # Verify payload bytes were copied
  assert buf[UdpHdrLen + 0] == 0xDE'u8, "payload byte 0"
  assert buf[UdpHdrLen + 1] == 0xAD'u8, "payload byte 1"
  echo "PASS: UDP encode/decode round-trip"

proc testUdpDecodeShort() =
  var buf: array[4, uint8]
  let (_, _, ok) = udpDecode(addr buf[0], buf.len)
  assert not ok, "udpDecode on short buffer must fail"
  echo "PASS: UDP decode rejects short buffer"

# ── Virtqueue ring layout ────────────────────────────────────────────────────

proc testVirtqueueLayout() =
  # Allocate a region big enough for the queue rings
  var mem: array[65536, uint8]
  # We cannot call virtqueueInit (needs MMIO), but we can verify
  # that ring objects are the right size and that our offset math
  # places them without overlap.
  let descSize  = uint64(QueueSize) * uint64(sizeof(VirtqDesc))
  assert sizeof(VirtqDesc) == 16, "VirtqDesc must be 16 bytes"
  assert descSize == uint64(QueueSize) * 16, "descriptor table size"

  # availRingOffset must be >= descSize
  let availOff = (descSize + 1) and not 1'u64
  let usedOff  = (availOff + uint64(sizeof(VirtqAvail)) + 3) and not 3'u64
  let total    = usedOff + uint64(sizeof(VirtqUsed))

  assert availOff >= descSize,  "avail ring must not overlap descriptor table"
  assert usedOff  >= availOff + uint64(sizeof(VirtqAvail)),
    "used ring must not overlap avail ring"
  assert total <= uint64(mem.len), "rings fit in test buffer"
  echo "PASS: Virtqueue ring layout — no overlaps"

proc testVirtqDescSize() =
  assert sizeof(VirtqDesc) == 16, "VirtqDesc: 8+4+2+2 = 16 bytes"
  assert sizeof(VirtqUsedElem) == 8, "VirtqUsedElem: 4+4 = 8 bytes"
  echo "PASS: VirtqDesc and VirtqUsedElem sizes correct"

# ── Main ─────────────────────────────────────────────────────────────────────

when isMainModule:
  testNetHdrSize()
  testEthernetRoundTrip()
  testEthernetDecodeShort()
  testIpChecksum()
  testIpEncodeDecodeRoundTrip()
  testUdpRoundTrip()
  testUdpDecodeShort()
  testVirtqueueLayout()
  testVirtqDescSize()
  echo "All virtio tests passed."
