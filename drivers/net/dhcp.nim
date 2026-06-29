# SPDX-License-Identifier: GPL-2.0
## DHCP — Dynamic Host Configuration Protocol (RFC 2131)
##
## Client-side DHCP state machine: DISCOVER → OFFER → REQUEST → ACK
## Assigns IP, netmask, gateway, DNS from QEMU's built-in DHCP server.

import ethernet
import ipv4
import udp
import arp

const
  DhcpServerPort* = 67
  DhcpClientPort* = 68
  DhcpMsgDiscover* = 1'u8
  DhcpMsgOffer* = 2'u8
  DhcpMsgRequest* = 3'u8
  DhcpMsgDecline* = 4'u8
  DhcpMsgAck* = 5'u8
  DhcpMsgNak* = 6'u8

  # DHCP options
  OptSubnetMask* = 1'u8
  OptRouter* = 3'u8
  OptDns* = 6'u8
  OptDhcpMsgType* = 53'u8
  OptDhcpServerId* = 54'u8
  OptLeaseTime* = 51'u8
  OptRequestedIpAddr* = 50'u8
  OptEnd* = 255'u8

type
  DhcpState* = enum
    dsInit
    dsDiscover  # sent DISCOVER, waiting for OFFER
    dsRequest   # sent REQUEST, waiting for ACK
    dsAcked      # got ACK, IP assigned
    dsTimeout    # lease expired or no response

  DhcpClientConfig* = object
    ip*: IpAddr
    netmask*: IpAddr
    gateway*: IpAddr
    dns*: IpAddr
    leaseTime*: uint32  # seconds

  DhcpClient* = object
    state*: DhcpState
    config*: DhcpClientConfig
    xid*: uint32          # transaction ID (random)
    offeredIp*: IpAddr    # IP offered by server
    serverId*: IpAddr     # DHCP server's IP
    lastTick*: uint64     # timestamp of last state change

# Wire format: DHCP message (simplified for DISCOVER/REQUEST/ACK path)
type
  DhcpMessage* = object
    op*: uint8           # 1=request, 2=reply
    htype*: uint8        # 1=Ethernet
    hlen*: uint8         # 6
    hops*: uint8
    xid*: uint32         # transaction ID
    secs*: uint16        # seconds since boot
    flags*: uint16       # bit 15=broadcast
    ciaddr*: uint32      # client IP (0 in DISCOVER)
    yiaddr*: uint32      # your IP (OFFER/ACK)
    siaddr*: uint32      # server IP
    giaddr*: uint32      # gateway IP (relay)
    chaddr*: array[6, uint8]  # client MAC
    sname*: array[64, uint8]  # server hostname (optional)
    file*: array[128, uint8]  # boot filename (optional)
    magic*: uint32       # 0x63825363 (DHCP cookie)
    options*: array[256, uint8]  # variable options

proc dhcpClientInit*(): DhcpClient =
  ## Initialize DHCP client in DISCOVER state
  var client: DhcpClient
  client.state = dsInit
  client.xid = 0x12345678  # TODO: random()
  client.lastTick = 0
  return client

proc dhcpBuildDiscover*(mac: EthAddr; xid: uint32): seq[uint8] =
  ## Construct a DHCP DISCOVER message
  var msg: DhcpMessage
  msg.op = 1  # BOOTREQUEST
  msg.htype = 1
  msg.hlen = 6
  msg.xid = xid
  msg.flags = 0x8000  # broadcast flag
  msg.magic = 0x63825363

  # Copy MAC
  for i in 0..5:
    msg.chaddr[i] = mac[i]

  # Build options (simplified)
  var optIdx = 0
  msg.options[optIdx] = OptDhcpMsgType
  msg.options[optIdx + 1] = 1  # length
  msg.options[optIdx + 2] = DhcpMsgDiscover
  optIdx += 3

  msg.options[optIdx] = OptEnd
  optIdx += 1

  # Serialize to bytes
  let msgBytes = cast[ptr UncheckedArray[uint8]](addr msg)
  let msgLen = 236 + optIdx  # fixed header + options
  result = newSeq[uint8](msgLen)
  for i in 0..<msgLen:
    result[i] = msgBytes[i]

proc dhcpBuildRequest*(mac: EthAddr; xid: uint32; requestedIp, serverId: IpAddr): seq[uint8] =
  ## Construct a DHCP REQUEST message (after receiving OFFER)
  var msg: DhcpMessage
  msg.op = 1  # BOOTREQUEST
  msg.htype = 1
  msg.hlen = 6
  msg.xid = xid
  msg.flags = 0x8000  # broadcast flag
  msg.magic = 0x63825363

  # Copy MAC
  for i in 0..5:
    msg.chaddr[i] = mac[i]

  # Build options
  var optIdx = 0
  msg.options[optIdx] = OptDhcpMsgType
  msg.options[optIdx + 1] = 1
  msg.options[optIdx + 2] = DhcpMsgRequest
  optIdx += 3

  # Requested IP
  msg.options[optIdx] = OptRequestedIpAddr
  msg.options[optIdx + 1] = 4
  let ipBytes = cast[ptr UncheckedArray[uint8]](addr requestedIp)
  for i in 0..3:
    msg.options[optIdx + 2 + i] = ipBytes[i]
  optIdx += 6

  # Server ID
  msg.options[optIdx] = OptDhcpServerId
  msg.options[optIdx + 1] = 4
  let srvIdBytes = cast[ptr UncheckedArray[uint8]](addr serverId)
  for i in 0..3:
    msg.options[optIdx + 2 + i] = srvIdBytes[i]
  optIdx += 6

  msg.options[optIdx] = OptEnd
  optIdx += 1

  # Serialize
  let msgBytes = cast[ptr UncheckedArray[uint8]](addr msg)
  let msgLen = 236 + optIdx
  result = newSeq[uint8](msgLen)
  for i in 0..<msgLen:
    result[i] = msgBytes[i]

proc dhcpParsePakcet*(data: ptr UncheckedArray[uint8]; dataLen: int): tuple[msgType: uint8, yiaddr: IpAddr, serverId: IpAddr, leaseTime: uint32] =
  ## Parse a DHCP server response (OFFER or ACK)
  # Minimal parsing: extract message type, offered IP, server ID, lease time from options
  if dataLen < 236:
    return (0, IpAddr(0), IpAddr(0), 0)

  let msg = cast[ptr DhcpMessage](data)
  let yiaddr = IpAddr(msg.yiaddr)

  var msgType = uint8(0)
  var serverId = IpAddr(0)
  var leaseTime = uint32(0)

  # Parse options
  var optIdx = 0
  while optIdx < 256:
    let opt = msg.options[optIdx]
    if opt == OptEnd:
      break
    if opt == OptDhcpMsgType:
      msgType = msg.options[optIdx + 2]
    elif opt == OptDhcpServerId:
      let idBytes = cast[ptr array[4, uint8]](addr msg.options[optIdx + 2])
      serverId = IpAddr(cast[uint32](idBytes[]))
    elif opt == OptLeaseTime:
      let timeBytes = cast[ptr array[4, uint8]](addr msg.options[optIdx + 2])
      leaseTime = cast[uint32](timeBytes[])

    let len = msg.options[optIdx + 1]
    optIdx += 2 + int(len)

  return (msgType, yiaddr, serverId, leaseTime)

proc dhcpHandle*(client: var DhcpClient; msg: seq[uint8]) =
  ## Process a received DHCP message (OFFER or ACK)
  let (msgType, yiaddr, serverId, leaseTime) = dhcpParsePakcet(cast[ptr UncheckedArray[uint8]](msg[0].unsafeAddr), msg.len)

  case client.state
  of dsDiscover:
    if msgType == DhcpMsgOffer:
      client.offeredIp = yiaddr
      client.serverId = serverId
      client.state = dsRequest
  of dsRequest:
    if msgType == DhcpMsgAck:
      client.config.ip = yiaddr
      client.config.leaseTime = leaseTime
      client.state = dsAcked
    elif msgType == DhcpMsgNak:
      client.state = dsInit
  else:
    discard
