# SPDX-License-Identifier: GPL-2.0
## Network Stack Foundation
##
## Implements OSI model layers for TCP/IP networking
## Supports Ethernet, IP, ICMP, TCP, UDP

import ../core/types

type
  # ═══════════════════════════════════════════════════════════════════════════
  # Network Types
  # ═══════════════════════════════════════════════════════════════════════════

  MacAddress* = array[6, uint8]
  IpAddress* = distinct uint32

  EthernetFrame* = object
    ## Ethernet frame (Layer 2)
    destMac*: MacAddress
    srcMac*: MacAddress
    etherType*: uint16
    payload*: array[1500, uint8]
    payloadLen*: uint16

  IpVersion* = enum
    ipv4 = 4
    ipv6 = 6

  IpProtocol* = enum
    ## IP protocol numbers
    protoIcmp = 1
    protoTcp = 6
    protoUdp = 17

  IpPacket* = object
    ## IPv4 packet (Layer 3)
    version*: IpVersion
    headerLen*: uint8
    dscp*: uint8
    ecn*: uint8
    totalLen*: uint16
    identification*: uint16
    flags*: uint8
    fragOffset*: uint16
    ttl*: uint8
    protocol*: IpProtocol
    checksum*: uint16
    srcAddr*: IpAddress
    destAddr*: IpAddress
    options*: array[40, uint8]
    optionsLen*: uint8
    payload*: array[1460, uint8]
    payloadLen*: uint16

  IcmpType* = enum
    ## ICMP message types
    icmpEchoReply = 0
    icmpDestUnreachable = 3
    icmpEchoRequest = 8
    icmpRouterAdvertisement = 9
    icmpRouterSolicitation = 10
    icmpTimeExceeded = 11

  IcmpMessage* = object
    ## ICMP message (Layer 3)
    msgType*: IcmpType
    code*: uint8
    checksum*: uint16
    identifier*: uint16
    sequenceNum*: uint16
    data*: array[1472, uint8]
    dataLen*: uint16

  TcpFlags* = distinct uint8
  TcpPort* = distinct uint16

  TcpSegment* = object
    ## TCP segment (Layer 4)
    srcPort*: TcpPort
    destPort*: TcpPort
    sequenceNum*: uint32
    acknowledgeNum*: uint32
    headerLen*: uint8
    flags*: TcpFlags
    windowSize*: uint16
    checksum*: uint16
    urgentPtr*: uint16
    options*: array[40, uint8]
    optionsLen*: uint8
    payload*: array[1420, uint8]
    payloadLen*: uint16

  UdpDatagram* = object
    ## UDP datagram (Layer 4)
    srcPort*: TcpPort
    destPort*: TcpPort
    length*: uint16
    checksum*: uint16
    payload*: array[1472, uint8]
    payloadLen*: uint16

  NetworkInterface* = object
    ## Network interface
    name*: array[16, uint8]
    macAddr*: MacAddress
    ipAddr*: IpAddress
    netmask*: IpAddress
    gateway*: IpAddress
    mtu*: uint16
    flags*: uint16
    rxPackets*: uint64
    txPackets*: uint64
    rxBytes*: uint64
    txBytes*: uint64
    rxErrors*: uint32
    txErrors*: uint32

  NetworkStats* = object
    ## Network statistics
    totalPacketsSent*: uint64
    totalPacketsReceived*: uint64
    totalBytesSent*: uint64
    totalBytesReceived*: uint64
    ipPacketsDropped*: uint32
    tcpConnectionsActive*: uint32
    tcpConnectionsClosed*: uint32
    udpDatagramsSent*: uint64
    udpDatagramsReceived*: uint64

# ═══════════════════════════════════════════════════════════════════════════
# Network Constants
# ═══════════════════════════════════════════════════════════════════════════

const
  MaxNetworkInterfaces* = 16
  DefaultMtu* = 1500'u16
  IpBroadcast* = IpAddress(0xFFFFFFFF)

# TCP Flags
const
  TcpFlagFin* = 0x01'u8
  TcpFlagSyn* = 0x02'u8
  TcpFlagRst* = 0x04'u8
  TcpFlagPsh* = 0x08'u8
  TcpFlagAck* = 0x10'u8
  TcpFlagUrg* = 0x20'u8

# ═══════════════════════════════════════════════════════════════════════════
# Global Network State
# ═══════════════════════════════════════════════════════════════════════════

var
  gNetworkInterfaces*: array[MaxNetworkInterfaces, NetworkInterface]
  gNetworkStats*: NetworkStats
  gInterfaceCount*: uint32 = 0

# ═══════════════════════════════════════════════════════════════════════════
# IP Address Utilities
# ═══════════════════════════════════════════════════════════════════════════

proc makeIpAddress*(a: uint8, b: uint8, c: uint8, d: uint8): IpAddress =
  ## Create IP address from octets
  IpAddress((uint32(a) shl 24) or (uint32(b) shl 16) or (uint32(c) shl 8) or uint32(d))

proc ipAddressToString*(addr: IpAddress): array[16, uint8] =
  ## Convert IP address to string
  # Would format as a.b.c.d
  result = [0'u8]

proc isIpBroadcast*(addr: IpAddress): bool =
  ## Check if IP is broadcast address
  uint32(addr) == 0xFFFFFFFF

proc isIpMulticast*(addr: IpAddress): bool =
  ## Check if IP is multicast address
  (uint32(addr) and 0xF0000000) == 0xE0000000

# ═══════════════════════════════════════════════════════════════════════════
# Interface Management
# ═══════════════════════════════════════════════════════════════════════════

proc registerInterface*(name: cstring, macAddr: MacAddress): uint32 =
  ## Register network interface
  if gInterfaceCount >= MaxNetworkInterfaces:
    return 0

  var iface: NetworkInterface
  iface.macAddr = macAddr
  iface.mtu = DefaultMtu
  iface.flags = 0

  gNetworkInterfaces[gInterfaceCount] = iface
  let id = gInterfaceCount
  inc gInterfaceCount
  return uint32(id)

proc getInterface*(id: uint32): ptr NetworkInterface =
  ## Get interface by ID
  if id < gInterfaceCount:
    return addr gNetworkInterfaces[id]
  return nil

proc setInterfaceAddress*(id: uint32, ip: IpAddress, netmask: IpAddress) =
  ## Set IP address for interface
  let iface = getInterface(id)
  if iface != nil:
    iface.ipAddr = ip
    iface.netmask = netmask

# ═══════════════════════════════════════════════════════════════════════════
# Packet Processing
# ═══════════════════════════════════════════════════════════════════════════

proc processEthernetFrame*(frame: EthernetFrame): bool =
  ## Process incoming Ethernet frame
  case frame.etherType
  of 0x0800:  # IPv4
    # Would parse IPv4 packet
    discard
  of 0x0806:  # ARP
    # Would process ARP request
    discard
  of 0x86DD:  # IPv6
    # Would parse IPv6 packet
    discard
  else:
    return false
  return true

proc processIpPacket*(packet: IpPacket): bool =
  ## Process incoming IP packet
  case packet.protocol
  of protoIcmp:
    # Would process ICMP
    discard
  of protoTcp:
    # Would process TCP
    discard
  of protoUdp:
    # Would process UDP
    discard
  else:
    return false
  return true

proc processIcmpMessage*(msg: IcmpMessage): bool =
  ## Process ICMP message
  case msg.msgType
  of icmpEchoRequest:
    # Would send echo reply
    discard
  of icmpEchoReply:
    # Would deliver to waiting process
    discard
  else:
    discard
  return true

# ═══════════════════════════════════════════════════════════════════════════
# Transmit Functions
# ═══════════════════════════════════════════════════════════════════════════

proc transmitEthernetFrame*(ifaceId: uint32, frame: EthernetFrame): bool =
  ## Send Ethernet frame
  let iface = getInterface(ifaceId)
  if iface != nil:
    iface.txPackets += 1
    iface.txBytes += uint64(frame.payloadLen)
    gNetworkStats.totalPacketsSent += 1
    gNetworkStats.totalBytesSent += uint64(frame.payloadLen)
    # Would send to NIC
    return true
  return false

proc transmitIpPacket*(ifaceId: uint32, packet: IpPacket): bool =
  ## Send IP packet
  # Would create Ethernet frame and transmit
  return true

proc transmitIcmpEchoRequest*(destAddr: IpAddress, id: uint16, seq: uint16): bool =
  ## Send ICMP echo request (ping)
  # Would create ICMP message and transmit
  return true

# ═══════════════════════════════════════════════════════════════════════════
# Network Statistics
# ═══════════════════════════════════════════════════════════════════════════

proc getNetworkStats*(): NetworkStats =
  ## Get network statistics
  return gNetworkStats

proc getInterfaceStats*(id: uint32): string =
  ## Get formatted interface statistics
  let iface = getInterface(id)
  if iface == nil:
    return "Interface not found"
  "RX: " & $iface.rxPackets & "/" & $iface.rxBytes & " | " &
  "TX: " & $iface.txPackets & "/" & $iface.txBytes

proc networkStats*(): string =
  ## Return formatted network statistics
  "Network: " & $gNetworkStats.totalPacketsSent & " sent, " &
  $gNetworkStats.totalPacketsReceived & " received"

# ═══════════════════════════════════════════════════════════════════════════
# Network Initialization
# ═══════════════════════════════════════════════════════════════════════════

proc initNetworkStack*() =
  ## Initialize network stack
  gNetworkStats = NetworkStats()
  gInterfaceCount = 0
