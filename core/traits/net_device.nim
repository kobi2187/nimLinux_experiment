# SPDX-License-Identifier: GPL-2.0
## Network device trait - LAYER 0
##
## Defines the interface for network devices (NICs)

import ../types

type
  # ═══════════════════════════════════════════════════════════════════════════
  # Network Device Flags
  # ═══════════════════════════════════════════════════════════════════════════

  NetDevFlags* = enum
    ## Network device state flags
    ndfUp           ## Interface is up
    ndfBroadcast    ## Supports broadcast
    ndfMulticast    ## Supports multicast
    ndfPromisc      ## Promiscuous mode
    ndfLoopback     ## Loopback interface
    ndfRunning      ## Interface is running
    ndfNoArp        ## No ARP protocol

  # ═══════════════════════════════════════════════════════════════════════════
  # Hardware Address Types
  # ═══════════════════════════════════════════════════════════════════════════

  MacAddress* = array[6, uint8]
    ## Ethernet MAC address

  HwAddrType* = enum
    ## Hardware address types
    hatEther = 1      ## Ethernet
    hatLoopback = 772 ## Loopback

  # ═══════════════════════════════════════════════════════════════════════════
  # Network Statistics
  # ═══════════════════════════════════════════════════════════════════════════

  NetStats* = object
    ## Network interface statistics
    rxPackets*: uint64     ## Received packets
    txPackets*: uint64     ## Transmitted packets
    rxBytes*: uint64       ## Received bytes
    txBytes*: uint64       ## Transmitted bytes
    rxErrors*: uint64      ## Receive errors
    txErrors*: uint64      ## Transmit errors
    rxDropped*: uint64     ## Received dropped
    txDropped*: uint64     ## Transmitted dropped
    multicast*: uint64     ## Multicast packets
    collisions*: uint64    ## Collisions
    rxLengthErrors*: uint64
    rxOverErrors*: uint64
    rxCrcErrors*: uint64
    rxFrameErrors*: uint64
    rxFifoErrors*: uint64
    txAbortedErrors*: uint64
    txCarrierErrors*: uint64
    txFifoErrors*: uint64
    txHeartbeatErrors*: uint64

  # ═══════════════════════════════════════════════════════════════════════════
  # Socket Buffer (simplified)
  # ═══════════════════════════════════════════════════════════════════════════

  SkBuff* = ref object
    ## Network packet buffer
    data*: pointer           ## Packet data pointer
    head*: pointer           ## Buffer start
    tail*: pointer           ## Data end
    bufEnd*: pointer         ## Buffer end

    len*: uint32             ## Data length
    dataLen*: uint32         ## Paged data length

    # Protocol headers
    macHeader*: uint16       ## MAC header offset
    networkHeader*: uint16   ## Network header offset
    transportHeader*: uint16 ## Transport header offset

    # Packet info
    protocol*: uint16        ## Ethernet protocol
    priority*: uint8         ## Packet priority

    # Routing/device
    dev*: NetDevice          ## Associated device

    # Queue linkage
    next*: SkBuff
    prev*: SkBuff

    # Private data
    private*: pointer

  # ═══════════════════════════════════════════════════════════════════════════
  # Network Device
  # ═══════════════════════════════════════════════════════════════════════════

  NetDevice* = ref object of RootObj
    ## Network device representation
    name*: array[16, char]      ## Interface name (e.g., "eth0")
    ifIndex*: int32             ## Interface index

    # Hardware info
    mac*: MacAddress            ## Hardware address
    hwAddrLen*: uint8           ## Hardware address length
    hwAddrType*: HwAddrType     ## Hardware type

    # Configuration
    mtu*: uint32                ## Maximum transmission unit
    minMtu*: uint32             ## Minimum MTU
    maxMtu*: uint32             ## Maximum MTU
    flags*: set[NetDevFlags]    ## Device flags

    # Features
    features*: uint64           ## Hardware features

    # Operations
    ops*: ptr NetDeviceOps      ## Device operations

    # Queues
    txQueue*: pointer           ## Transmit queue
    rxQueue*: pointer           ## Receive queue
    numTxQueues*: uint16        ## Number of TX queues
    numRxQueues*: uint16        ## Number of RX queues

    # Statistics
    stats*: NetStats            ## Interface statistics

    # State
    state*: uint32              ## Device state

    # Private
    private*: pointer           ## Driver private data

  NetDeviceOps* = object
    ## Network device operations
    open*: proc(dev: NetDevice): Result[void, int] {.nimcall.}
    stop*: proc(dev: NetDevice): Result[void, int] {.nimcall.}
    startXmit*: proc(dev: NetDevice, skb: SkBuff): Result[void, int] {.nimcall.}
    setMacAddress*: proc(dev: NetDevice, address: MacAddress): Result[void, int] {.nimcall.}
    setMtu*: proc(dev: NetDevice, mtu: uint32): Result[void, int] {.nimcall.}
    getStats*: proc(dev: NetDevice): NetStats {.nimcall.}
    validate*: proc(dev: NetDevice): Result[void, int] {.nimcall.}
    ioctl*: proc(dev: NetDevice, cmd: uint32, arg: pointer): Result[int, int] {.nimcall.}
    setFeatures*: proc(dev: NetDevice, features: uint64): Result[void, int] {.nimcall.}
    poll*: proc(dev: NetDevice, budget: int): int {.nimcall.}  ## NAPI poll

# ═══════════════════════════════════════════════════════════════════════════
# Network Constants
# ═══════════════════════════════════════════════════════════════════════════

const
  ETH_ALEN* = 6                   ## Ethernet address length
  ETH_HLEN* = 14                  ## Ethernet header length
  ETH_MTU* = 1500'u32             ## Standard Ethernet MTU
  ETH_MIN_MTU* = 68'u32           ## Minimum MTU
  ETH_MAX_MTU* = 65535'u32        ## Maximum MTU

  # Ethernet protocols (big endian values)
  ETH_P_IP*    = 0x0800'u16       ## IPv4
  ETH_P_ARP*   = 0x0806'u16       ## ARP
  ETH_P_IPV6*  = 0x86DD'u16       ## IPv6
  ETH_P_8021Q* = 0x8100'u16       ## 802.1Q VLAN

  # Broadcast address
  ETH_BROADCAST*: MacAddress = [0xFF'u8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]

# ═══════════════════════════════════════════════════════════════════════════
# Helper Functions
# ═══════════════════════════════════════════════════════════════════════════

proc isUp*(dev: NetDevice): bool {.inline.} =
  ndfUp in dev.flags

proc isRunning*(dev: NetDevice): bool {.inline.} =
  ndfRunning in dev.flags

proc isLoopback*(dev: NetDevice): bool {.inline.} =
  ndfLoopback in dev.flags

proc supportsMulticast*(dev: NetDevice): bool {.inline.} =
  ndfMulticast in dev.flags

proc isBroadcast*(mac: MacAddress): bool {.inline.} =
  mac == ETH_BROADCAST

proc isMulticast*(mac: MacAddress): bool {.inline.} =
  (mac[0] and 0x01) != 0

proc isLocal*(mac: MacAddress): bool {.inline.} =
  ## Check if locally administered address
  (mac[0] and 0x02) != 0

proc getName*(dev: NetDevice): string =
  ## Get device name as string
  var i = 0
  while i < dev.name.len and dev.name[i] != '\0':
    inc i
  result = newString(i)
  for j in 0..<i:
    result[j] = dev.name[j]

proc `$`*(mac: MacAddress): string =
  ## Format MAC address as string
  const hexChars = "0123456789abcdef"
  result = newString(17)
  for i in 0..<6:
    result[i*3] = hexChars[(mac[i] shr 4) and 0xF]
    result[i*3+1] = hexChars[mac[i] and 0xF]
    if i < 5:
      result[i*3+2] = ':'
