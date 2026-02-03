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
# Global Port Registry and Message Queue
# ═══════════════════════════════════════════════════════════════════════════

var
  gPorts*: array[MaxPorts, Port]
  gPortCount*: uint32 = 0
  gNextPortId*: uint32 = 1
  gLoopers*: array[MaxLoopers, Looper]
  gLooperCount*: uint32 = 0

# Message queue: simple ring buffer per port
type
  MessageQueue = object
    messages: array[128, Message]
    head: uint32
    tail: uint32
    count: uint32

var gMessageQueues*: array[MaxPorts, MessageQueue]

# Port naming registry
type
  PortName = object
    name: array[32, uint8]
    portId: uint32

var gPortNames*: array[64, PortName]
var gPortNameCount: uint32 = 0

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
# Message Queue Operations - Forth-style: core then high-level
# ═══════════════════════════════════════════════════════════════════════════

proc queue_is_full(portId: uint32): bool =
  ## Check if message queue is full
  # Strategy: Compare count against capacity
  let portIdx = portId mod MaxPorts
  gMessageQueues[portIdx].count >= 128

proc queue_is_empty(portId: uint32): bool =
  ## Check if message queue is empty
  # Strategy: Check if count is zero
  let portIdx = portId mod MaxPorts
  gMessageQueues[portIdx].count == 0

proc queue_enqueue(portId: uint32, msg: ptr Message): bool =
  ## Add message to queue
  # Strategy: Copy message into ring buffer at tail, advance tail
  let portIdx = portId mod MaxPorts
  var queue = addr gMessageQueues[portIdx]

  if queue.count >= 128:
    return false

  queue.messages[queue.tail] = msg[]
  queue.tail = (queue.tail + 1) mod 128
  inc queue.count
  return true

proc queue_dequeue(portId: uint32): ptr Message =
  ## Remove message from queue
  # Strategy: Get message from head, advance head, return pointer
  let portIdx = portId mod MaxPorts
  var queue = addr gMessageQueues[portIdx]

  if queue.count == 0:
    return nil

  let msg = addr queue.messages[queue.head]
  queue.head = (queue.head + 1) mod 128
  dec queue.count
  return msg

proc queue_peek(portId: uint32): ptr Message =
  ## Look at next message without removing
  # Strategy: Return pointer to head message if available
  let portIdx = portId mod MaxPorts
  var queue = addr gMessageQueues[portIdx]

  if queue.count == 0:
    return nil

  return addr queue.messages[queue.head]

# ─── High-level message operations ───

proc sendMessage*(destPortId: uint32, msg: ptr Message): bool =
  ## Send message to port (non-blocking)
  # Strategy: Check port exists, queue message, update count
  let port = getPort(destPortId)
  if port == nil:
    return false

  if not queue_enqueue(destPortId, msg):
    return false

  inc port.msgCount
  return true

proc sendMessageSync*(destPortId: uint32, msg: ptr Message, timeoutMs: uint32 = 1000): bool =
  ## Send message and wait for reply (blocking)
  # Strategy: Send message with reply-expected flag, poll for reply
  # In real implementation: Would block on condition variable
  if msg == nil:
    return false

  msg.replyExpected = true

  # Send the message
  if not sendMessage(destPortId, msg):
    return false

  # In real implementation: would wait on replyPort with timeout
  # For now: return true indicating sent (reply handling async)
  return true

proc getMessage*(portId: uint32): Message =
  ## Receive message from port (blocking)
  # Strategy: Wait until message available, dequeue and return
  # In real implementation: Would block on condition variable or poll
  var result: Message

  # For now: non-blocking peek + spin (should be async in real OS)
  let msg = queue_peek(portId)
  if msg != nil:
    result = msg[]

  return result

proc getMessageNonblock*(portId: uint32): ptr Message =
  ## Try to receive message (non-blocking)
  # Strategy: Check queue, dequeue if available, return pointer or nil
  let port = getPort(portId)
  if port == nil or port.msgCount == 0:
    return nil

  let msg = queue_dequeue(portId)
  if msg != nil:
    dec port.msgCount

  return msg

proc peekMessage*(portId: uint32): ptr Message =
  ## Look at next message without removing
  # Strategy: Peek at queue head
  if getPort(portId) == nil:
    return nil

  return queue_peek(portId)

proc replyToMessage*(origMsg: ptr Message, replyMsg: ptr Message): bool =
  ## Send reply to original sender
  # Strategy: If reply expected, send to reply port
  if origMsg == nil or replyMsg == nil:
    return false

  if not origMsg.replyExpected:
    return false

  replyMsg.what = origMsg.what
  return sendMessage(origMsg.replyPort, replyMsg)

# ═══════════════════════════════════════════════════════════════════════════
# Handler Registration and Dispatch - Forth-style function composition
# ═══════════════════════════════════════════════════════════════════════════

# Handler registry: per-port message routing
type
  MessageRouter = object
    handlers: array[MaxHandlers, Handler]
    count: uint16

var gHandlerRouters*: array[MaxPorts, MessageRouter]

proc add_handler_to_router(portId: uint32, msgCode: MessageCode, handler: proc(msg: ptr Message), name: cstring): bool =
  ## Add handler to port's routing table
  # Strategy: Find space in port's handler array, store handler
  let portIdx = portId mod MaxPorts
  var router = addr gHandlerRouters[portIdx]

  if router.count >= MaxHandlers:
    return false

  router.handlers[router.count].portId = portId
  router.handlers[router.count].handlerFunc = handler
  router.count += 1
  return true

proc find_handler_for_message(portId: uint32, msgCode: MessageCode): proc(msg: ptr Message) =
  ## Find handler for message code
  # Strategy: Search handlers for matching code or catch-all
  let portIdx = portId mod MaxPorts
  let router = addr gHandlerRouters[portIdx]

  # Handler dispatch: iterate through registered handlers
  # In real implementation: would have msgCode field in Handler
  # For now: return nil (not found)
  return nil

proc addHandler*(portId: uint32, msgCode: MessageCode, handler: proc(msg: ptr Message)) =
  ## Register message handler for specific message code
  # Strategy: Add to port's handler routing table
  let port = getPort(portId)
  if port == nil:
    return

  discard add_handler_to_router(portId, msgCode, handler, "")

proc removeHandler*(portId: uint32, msgCode: MessageCode): bool =
  ## Unregister message handler
  # Strategy: Find and remove handler from routing table
  let port = getPort(portId)
  if port == nil:
    return false

  # Would search handlers and remove matching one
  return false

# ═══════════════════════════════════════════════════════════════════════════
# Looper Architecture - BeOS message dispatch loop pattern
# ═══════════════════════════════════════════════════════════════════════════

proc looper_validate(looperId: uint32): bool =
  ## Check if looper ID is valid
  # Strategy: Bounds check
  return looperId < gLooperCount

proc looper_get(looperId: uint32): ptr Looper =
  ## Get looper by ID
  # Strategy: Index array if valid
  if not looper_validate(looperId):
    return nil
  return addr gLoopers[looperId]

proc looper_dispatch_message(looper: ptr Looper, msg: ptr Message): bool =
  ## Dispatch message to matching handler
  # Strategy: Search handlers, call matching one
  if looper == nil or msg == nil:
    return false

  # Check handlers for this message
  for i in 0..<looper.handlerCount:
    if looper.handlers[i].handlerFunc != nil:
      looper.handlers[i].handlerFunc(msg)
      return true

  return false

proc looper_process_one_message(looperId: uint32): bool =
  ## Process single message from looper's port
  # Strategy: Get next message, dispatch it
  let looper = looper_get(looperId)
  if looper == nil:
    return false

  let msg = getMessageNonblock(looper.portId)
  if msg == nil:
    return false

  return looper_dispatch_message(looper, msg)

proc createLooper*(name: cstring = ""): uint32 =
  ## Create message looper (like BLooper in BeOS)
  # Strategy: Allocate looper, create port, initialize handler array
  if gLooperCount >= MaxLoopers:
    return 0

  var looper: Looper
  looper.portId = createPort(DefaultPortCapacity, name)
  if looper.portId == 0:
    return 0

  looper.isRunning = false
  looper.handlerCount = 0

  gLoopers[gLooperCount] = looper
  let id = gLooperCount
  inc gLooperCount
  return uint32(id)

proc registerLooperHandler*(looperId: uint32, handler: proc(msg: ptr Message), name: cstring = ""): bool =
  ## Register message handler in looper
  # Strategy: Add to looper's handler array
  let looper = looper_get(looperId)
  if looper == nil or looper.handlerCount >= 16:
    return false

  looper.handlers[looper.handlerCount].handlerFunc = handler
  looper.handlerCount += 1
  return true

proc startLooper*(looperId: uint32): bool =
  ## Start looper processing messages
  # Strategy: Set running flag (in real OS would spawn thread)
  let looper = looper_get(looperId)
  if looper == nil:
    return false

  looper.isRunning = true
  return true

proc stopLooper*(looperId: uint32): bool =
  ## Stop looper (graceful shutdown)
  # Strategy: Set running flag to false, threads would see it
  let looper = looper_get(looperId)
  if looper == nil:
    return false

  looper.isRunning = false
  return true

proc looperProcessMessages*(looperId: uint32) =
  ## Process all pending messages on looper (blocking loop)
  # Strategy: Continuously process messages while running
  # In real OS: Would run in separate thread
  let looper = looper_get(looperId)
  if looper == nil:
    return

  while looper.isRunning:
    # Process one message at a time
    if not looper_process_one_message(looperId):
      # No messages available, would sleep/yield here
      break

proc looperGetPortId*(looperId: uint32): uint32 =
  ## Get the port ID for a looper
  # Strategy: Return port from looper struct
  let looper = looper_get(looperId)
  if looper == nil:
    return 0
  return looper.portId

proc looperGetPendingCount*(looperId: uint32): uint32 =
  ## Get number of pending messages
  # Strategy: Check port message count
  let looper = looper_get(looperId)
  if looper == nil:
    return 0

  let port = getPort(looper.portId)
  if port == nil:
    return 0

  return port.msgCount

# ═══════════════════════════════════════════════════════════════════════════
# Port Naming Service - Symbolic port lookup
# ═══════════════════════════════════════════════════════════════════════════

proc string_to_name_entry(src: cstring): array[32, uint8] =
  ## Convert cstring to fixed-size name array
  # Strategy: Copy until null or 32 bytes reached
  var result: array[32, uint8]
  if src != nil:
    var i = 0
    while i < 31:
      let byte = cast[ptr uint8](cast[uint64](src) + i)[]
      if byte == 0:
        break
      result[i] = byte
      i += 1
    result[i] = 0
  return result

proc name_matches(stored: array[32, uint8], query: cstring): bool =
  ## Check if stored name matches query
  # Strategy: Compare until first null in either
  var i = 0
  let queryPtr = cast[ptr uint8](query)
  while i < 32:
    if stored[i] == 0 and queryPtr[i] == 0:
      return true
    if stored[i] != queryPtr[i]:
      return false
    i += 1
  return true

proc findPortByName*(name: cstring): uint32 =
  ## Look up port by symbolic name
  # Strategy: Search port name registry for exact match
  # Well-known ports: "app_server", "midi_server", etc
  if name == nil:
    return 0

  for i in 0..<gPortNameCount:
    if name_matches(gPortNames[i].name, name):
      return gPortNames[i].portId

  return 0

proc registerPortName*(portId: uint32, name: cstring): bool =
  ## Register port in naming service
  # Strategy: Check port exists, add to name registry
  let port = getPort(portId)
  if port == nil:
    return false

  if gPortNameCount >= 64:
    return false

  gPortNames[gPortNameCount].name = string_to_name_entry(name)
  gPortNames[gPortNameCount].portId = portId
  inc gPortNameCount
  return true

proc unregisterPortName*(name: cstring): bool =
  ## Unregister port name
  # Strategy: Find and remove from registry
  if name == nil:
    return false

  for i in 0..<gPortNameCount:
    if name_matches(gPortNames[i].name, name):
      # Shift remaining entries
      for j in i..<gPortNameCount - 1:
        gPortNames[j] = gPortNames[j + 1]
      dec gPortNameCount
      return true

  return false

proc findPortIdByName*(name: cstring): uint32 =
  ## Find port by well-known name
  # Strategy: Lookup in naming service, return ID
  return findPortByName(name)

# ═══════════════════════════════════════════════════════════════════════════
# Statistics and Introspection - Monitoring and debugging utilities
# ═══════════════════════════════════════════════════════════════════════════

proc count_total_messages*(): uint32 =
  ## Count all messages currently queued
  # Strategy: Sum message count across all ports
  var total = 0'u32
  for i in 0..<gPortCount:
    total += gPorts[i].msgCount
  return total

proc count_active_loopers*(): uint32 =
  ## Count running loopers
  # Strategy: Count loopers with isRunning = true
  var count = 0'u32
  for i in 0..<gLooperCount:
    if gLoopers[i].isRunning:
      inc count
  return count

proc portStats*(): string =
  ## Get port statistics
  # Strategy: Format current resource usage
  "Ports: " & $gPortCount & "/" & $MaxPorts &
  " | Loopers: " & $gLooperCount & "/" & $MaxLoopers &
  " | Messages: " & $count_total_messages()

proc getPortInfo*(portId: uint32): string =
  ## Get formatted port information
  # Strategy: Look up port, format its status
  let port = getPort(portId)
  if port == nil:
    return "Port not found"

  "Port " & $port.portId & ": " & $port.msgCount & "/" &
  $port.capacity & " messages"

proc listPorts*(): string =
  ## List all active ports
  # Strategy: Iterate ports, build formatted list
  var result = "Active Ports:\n"
  for i in 0..<gPortCount:
    result = result & "  Port " & $gPorts[i].portId & ": " &
      $gPorts[i].msgCount & "/" & $gPorts[i].capacity & " msgs\n"
  return result

proc listLoopers*(): string =
  ## List all active loopers
  # Strategy: Iterate loopers, show status
  var result = "Active Loopers:\n"
  for i in 0..<gLooperCount:
    let status = if gLoopers[i].isRunning: "RUNNING" else: "STOPPED"
    result = result & "  Looper " & $i & ": port=" &
      $gLoopers[i].portId & " [" & status & "]\n"
  return result

proc listNamedPorts*(): string =
  ## List all named ports
  # Strategy: Show port name registry
  var result = "Named Ports:\n"
  for i in 0..<gPortNameCount:
    result = result & "  " & $gPortNames[i].portId & " -> " &
      $gPortNames[i].name[0] & "\n"
  return result
