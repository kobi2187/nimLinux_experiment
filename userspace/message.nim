# SPDX-License-Identifier: GPL-2.0
## BeOS-Style Message System
##
## Port-based message passing architecture
## Every application/service is message-based (no shared memory by default)

import ../core/types

type
  # ═══════════════════════════════════════════════════════════════════════════
  # Message Types
  # ═══════════════════════════════════════════════════════════════════════════

  MessageCode* = distinct uint32

  Message* = object
    ## Generic BeOS-style message
    what*: MessageCode              ## Message type identifier
    sender*: uint32                 ## Sender port ID
    replyExpected*: bool            ## Sender expects reply
    replyPort*: uint32              ## Port to send reply to
    timestamp*: uint64              ## When message was sent

    # Fixed fields
    intField1*, intField2*: int32
    intField3*, intField4*: int32

    # Variable data section
    dataSize*: uint32
    data*: array[512, uint8]

  Port* = object
    ## Message port - target for messages
    portId*: uint32
    ownerPid*: uint32
    capacity*: uint32               ## Max queued messages
    msgCount*: uint32               ## Current message count
    flags*: uint16
    name*: array[32, uint8]

  Handler* = object
    ## Message handler callback
    portId*: uint32
    handlerFunc*: proc(msg: ptr Message)
    name*: array[64, uint8]

  Looper* = object
    ## Message processing loop (BeOS Looper equivalent)
    portId*: uint32
    threadId*: uint32
    isRunning*: bool
    handlers*: array[16, Handler]
    handlerCount*: uint8
    name*: array[64, uint8]

# ═══════════════════════════════════════════════════════════════════════════
# Message Constants
# ═══════════════════════════════════════════════════════════════════════════

const
  MaxPorts* = 1024
  MaxHandlers* = 256
  MaxLoopers* = 128
  DefaultPortCapacity* = 32

  # Standard message codes
  MsgQuit* = MessageCode(0x51495420)         ## 'QUIT'
  MsgReady* = MessageCode(0x52454459)        ## 'REDY'
  MsgError* = MessageCode(0x4552524F)        ## 'ERRO'

# ═══════════════════════════════════════════════════════════════════════════
# Global Port Registry
# ═══════════════════════════════════════════════════════════════════════════

var
  gPorts*: array[MaxPorts, Port]
  gPortCount*: uint32 = 0
  gNextPortId*: uint32 = 1
  gLoopers*: array[MaxLoopers, Looper]
  gLooperCount*: uint32 = 0

# ═══════════════════════════════════════════════════════════════════════════
# Port Operations
# ═══════════════════════════════════════════════════════════════════════════

proc createPort*(capacity: uint32 = DefaultPortCapacity, name: cstring = ""): uint32 =
  ## Create a new message port
  ## Returns port ID
  if gPortCount >= MaxPorts:
    return 0

  var port: Port
  port.portId = gNextPortId
  inc gNextPortId
  port.ownerPid = 0  # Would be current process
  port.capacity = capacity
  port.msgCount = 0

  gPorts[gPortCount] = port
  inc gPortCount
  return port.portId

proc deletePort*(portId: uint32): bool =
  ## Delete a port
  for i in 0..<gPortCount:
    if gPorts[i].portId == portId:
      # Remove from array
      for j in i..<gPortCount - 1:
        gPorts[j] = gPorts[j + 1]
      if gPortCount > 0:
        dec gPortCount
      return true
  return false

proc getPort*(portId: uint32): ptr Port =
  ## Get port by ID
  for i in 0..<gPortCount:
    if gPorts[i].portId == portId:
      return addr gPorts[i]
  return nil

# ═══════════════════════════════════════════════════════════════════════════
# Message Operations
# ═══════════════════════════════════════════════════════════════════════════

proc sendMessage*(destPortId: uint32, msg: ptr Message): bool =
  ## Send message to port (non-blocking)
  let port = getPort(destPortId)
  if port == nil or port.msgCount >= port.capacity:
    return false

  # Queue message
  inc port.msgCount
  return true

proc sendMessageSync*(destPortId: uint32, msg: ptr Message, timeoutMs: uint32 = 1000): bool =
  ## Send message and wait for reply (blocking)
  let port = getPort(destPortId)
  if port == nil:
    return false

  # Send and wait for reply port
  # Would block until reply arrives or timeout
  return true

proc getMessage*(portId: uint32): Message =
  ## Receive message from port (blocking)
  # Would block until message available
  result.what = MessageCode(0)

proc getMessageNonblock*(portId: uint32): ptr Message =
  ## Try to receive message (non-blocking)
  let port = getPort(portId)
  if port != nil and port.msgCount > 0:
    dec port.msgCount
    # Would return pointer to message
  return nil

proc replyToMessage*(origMsg: ptr Message, replyMsg: ptr Message): bool =
  ## Send reply to original sender
  if not origMsg.replyExpected:
    return false
  return sendMessage(origMsg.replyPort, replyMsg)

# ═══════════════════════════════════════════════════════════════════════════
# Handler Registration
# ═══════════════════════════════════════════════════════════════════════════

proc addHandler*(portId: uint32, msgCode: MessageCode, handler: proc(msg: ptr Message)) =
  ## Register message handler for specific message code
  let port = getPort(portId)
  if port == nil:
    return

  # Handler registration would be attached to port
  discard

proc removeHandler*(portId: uint32, msgCode: MessageCode): bool =
  ## Unregister message handler
  discard

# ═══════════════════════════════════════════════════════════════════════════
# Looper Architecture
# ═══════════════════════════════════════════════════════════════════════════

proc createLooper*(name: cstring = ""): uint32 =
  ## Create message looper (like BLooper)
  if gLooperCount >= MaxLoopers:
    return 0

  var looper: Looper
  looper.portId = createPort()
  looper.isRunning = false

  gLoopers[gLooperCount] = looper
  let id = gLooperCount
  inc gLooperCount
  return uint32(id)

proc startLooper*(looperId: uint32): bool =
  ## Start looper processing messages
  if looperId >= gLooperCount:
    return false
  gLoopers[looperId].isRunning = true
  # Would spawn thread to run message loop
  return true

proc stopLooper*(looperId: uint32): bool =
  ## Stop looper
  if looperId >= gLooperCount:
    return false
  gLoopers[looperId].isRunning = false
  return true

proc looperProcessMessages*(looperId: uint32) =
  ## Process all pending messages on looper
  if looperId >= gLooperCount:
    return
  let looper = addr gLoopers[looperId]
  # Would run message processing loop
  # Dispatch messages to handlers
  discard

# ═══════════════════════════════════════════════════════════════════════════
# Port Naming Service
# ═══════════════════════════════════════════════════════════════════════════

proc findPortByName*(name: cstring): uint32 =
  ## Look up port by symbolic name
  # Well-known ports: "app_server", "midi_server", etc
  return 0

proc registerPortName*(portId: uint32, name: cstring): bool =
  ## Register port in naming service
  let port = getPort(portId)
  if port == nil:
    return false
  # Would add to name service registry
  return true

# ═══════════════════════════════════════════════════════════════════════════
# Statistics
# ═══════════════════════════════════════════════════════════════════════════

proc portStats*(): string =
  ## Get port statistics
  "Ports: " & $gPortCount & "/" & $MaxPorts &
  " | Loopers: " & $gLooperCount & "/" & $MaxLoopers

proc getPortInfo*(portId: uint32): string =
  ## Get formatted port information
  let port = getPort(portId)
  if port == nil:
    return "Port not found"
  "Port " & $port.portId & ": " & $port.msgCount & "/" &
  $port.capacity & " messages"
