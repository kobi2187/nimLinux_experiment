# SPDX-License-Identifier: GPL-2.0
## ARP — Address Resolution Protocol (RFC 826)
##
## Resolves IPv4 addresses to Ethernet MAC addresses on the local link.
## Maintains a fixed-size arp_cache[IP→MAC] table.
##
## Wire layout (28-byte payload, ethertype 0x0806):
##   u16 htype  = 1 (Ethernet)
##   u16 ptype  = 0x0800 (IPv4)
##   u8  hlen   = 6 (MAC length)
##   u8  plen   = 4 (IP length)
##   u16 oper   = 1 (request) or 2 (reply)
##   u8[6] sha  — sender hardware address (MAC)
##   u32   spa  — sender protocol address (IP, network byte order)
##   u8[6] tha  — target hardware address (MAC; zeroes in request)
##   u32   tpa  — target protocol address (IP, network byte order)

import ethernet
import ipv4

const
  EthertypeArp*   = 0x0806'u16
  ArpHdrLen*      = 28       # fixed for Ethernet/IPv4
  ArpOpRequest*   = 1'u16
  ArpOpReply*     = 2'u16
  ArpCacheMax*    = 16       # entries in the cache table

type
  ArpEntry* = object
    ip*:    IpAddr
    mac*:   EthAddr
    valid*: bool

  ArpPacket* = object
    oper*: uint16
    sha*:  EthAddr  # sender MAC
    spa*:  IpAddr   # sender IP
    tha*:  EthAddr  # target MAC
    tpa*:  IpAddr   # target IP

var arpCache*: array[ArpCacheMax, ArpEntry]

# ── Cache helpers ─────────────────────────────────────────────────────────────

proc arpCacheLookup*(ip: IpAddr): ptr ArpEntry =
  ## Return pointer to the cache entry for ip, or nil if not found.
  for i in 0..<ArpCacheMax:
    if arpCache[i].valid and arpCache[i].ip == ip:
      return addr arpCache[i]
  nil

proc arpCacheInsert*(ip: IpAddr; mac: EthAddr) =
  ## Insert or update an entry. Evicts the first empty slot; wraps on full.
  for i in 0..<ArpCacheMax:
    if not arpCache[i].valid or arpCache[i].ip == ip:
      arpCache[i] = ArpEntry(ip: ip, mac: mac, valid: true)
      return
  # Cache full: evict slot 0 (simple LRU approximation)
  arpCache[0] = ArpEntry(ip: ip, mac: mac, valid: true)

proc arpCacheInvalidate*(ip: IpAddr) =
  for i in 0..<ArpCacheMax:
    if arpCache[i].valid and arpCache[i].ip == ip:
      arpCache[i].valid = false

# ── Wire encode/decode ────────────────────────────────────────────────────────

proc writeU16Be(dst: ptr UncheckedArray[uint8]; off: int; v: uint16) {.inline.} =
  dst[off]   = uint8(v shr 8)
  dst[off+1] = uint8(v and 0xFF)

proc readU16Be(src: ptr UncheckedArray[uint8]; off: int): uint16 {.inline.} =
  (uint16(src[off]) shl 8) or uint16(src[off+1])

proc writeU32Be(dst: ptr UncheckedArray[uint8]; off: int; v: uint32) {.inline.} =
  dst[off]   = uint8(v shr 24)
  dst[off+1] = uint8((v shr 16) and 0xFF)
  dst[off+2] = uint8((v shr 8) and 0xFF)
  dst[off+3] = uint8(v and 0xFF)

proc readU32Be(src: ptr UncheckedArray[uint8]; off: int): uint32 {.inline.} =
  (uint32(src[off]) shl 24) or (uint32(src[off+1]) shl 16) or
  (uint32(src[off+2]) shl 8) or uint32(src[off+3])

proc arpEncode*(buf: pointer; pkt: ArpPacket): int =
  ## Encode an ARP packet into buf. Returns ArpHdrLen (28).
  let b = cast[ptr UncheckedArray[uint8]](buf)
  writeU16Be(b, 0,  1'u16)          # htype = Ethernet
  writeU16Be(b, 2,  0x0800'u16)     # ptype = IPv4
  b[4] = 6'u8                        # hlen
  b[5] = 4'u8                        # plen
  writeU16Be(b, 6,  pkt.oper)
  for i in 0..<6: b[8  + i] = pkt.sha[i]
  writeU32Be(b, 14, pkt.spa)
  for i in 0..<6: b[18 + i] = pkt.tha[i]
  writeU32Be(b, 24, pkt.tpa)
  ArpHdrLen

proc arpDecode*(buf: pointer; len: int): tuple[pkt: ArpPacket; ok: bool] =
  ## Decode an ARP packet. ok=false if buf is too short or not Ethernet/IPv4.
  if len < ArpHdrLen:
    return (ArpPacket(), false)
  let b = cast[ptr UncheckedArray[uint8]](buf)
  if readU16Be(b, 0) != 1'u16:       return (ArpPacket(), false)  # htype
  if readU16Be(b, 2) != 0x0800'u16:  return (ArpPacket(), false)  # ptype
  if b[4] != 6 or b[5] != 4:         return (ArpPacket(), false)  # hlen/plen
  var pkt: ArpPacket
  pkt.oper = readU16Be(b, 6)
  for i in 0..<6: pkt.sha[i] = b[8  + i]
  pkt.spa  = readU32Be(b, 14)
  for i in 0..<6: pkt.tha[i] = b[18 + i]
  pkt.tpa  = readU32Be(b, 24)
  (pkt, true)

# ── High-level send helpers ───────────────────────────────────────────────────

proc arpBuildRequest*(outBuf: pointer; senderMac: EthAddr; senderIp, targetIp: IpAddr): int =
  ## Build a complete Ethernet frame containing an ARP request.
  ## Returns total frame length, or 0 on error.
  ## outBuf must be at least EthHdrLen + ArpHdrLen bytes.
  let broadcastMac: EthAddr = [0xFF'u8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
  let zeroMac:      EthAddr = [0x00'u8, 0x00, 0x00, 0x00, 0x00, 0x00]
  let frameLen = ethEncode(outBuf, broadcastMac, senderMac, EthertypeArp, ArpHdrLen)
  let b = cast[ptr UncheckedArray[uint8]](outBuf)
  let pkt = ArpPacket(
    oper: ArpOpRequest,
    sha:  senderMac,
    spa:  senderIp,
    tha:  zeroMac,
    tpa:  targetIp
  )
  discard arpEncode(addr b[EthHdrLen], pkt)
  frameLen

proc arpBuildReply*(outBuf: pointer; senderMac: EthAddr; senderIp: IpAddr;
                    pkt: ArpPacket): int =
  ## Build a complete Ethernet frame containing an ARP reply to the given request.
  ## Returns total frame length.
  let frameLen = ethEncode(outBuf, pkt.sha, senderMac, EthertypeArp, ArpHdrLen)
  let b = cast[ptr UncheckedArray[uint8]](outBuf)
  let reply = ArpPacket(
    oper: ArpOpReply,
    sha:  senderMac,
    spa:  senderIp,
    tha:  pkt.sha,
    tpa:  pkt.spa
  )
  discard arpEncode(addr b[EthHdrLen], reply)
  frameLen

proc arpHandleFrame*(payload: pointer; payloadLen: int): tuple[pkt: ArpPacket; needReply: bool] =
  ## Process an incoming ARP frame (payload = after Ethernet header).
  ## Always updates the cache from sender info.
  ## Returns needReply=true if oper==request; caller sends the reply via
  ## arpBuildReply + virtioNetSend. Not called with ourIp to stay driver-free.
  let (pkt, ok) = arpDecode(payload, payloadLen)
  if not ok:
    return (ArpPacket(), false)
  arpCacheInsert(pkt.spa, pkt.sha)
  (pkt, pkt.oper == ArpOpRequest)
