# SPDX-License-Identifier: GPL-2.0
## High-Performance Message Queue using Arsenal Lock-Free Queues
##
## Alternative implementation using arsenal library's SPSC/MPMC queues
## for message passing without locks or busy-waiting. Optimized for
## BeOS-style message-driven architecture.
##
## Performance characteristics:
## - Lock-free (no mutexes, spinlocks, or atomic compare-and-swap)
## - Wait-free on dequeue path (no retry loops)
## - Cache-friendly with padding to avoid false sharing
## - No dynamic allocation (fixed-size message queues)

import ../core/types
import ../kern/arsenal_adapters

type
  # ═══════════════════════════════════════════════════════════════════════════
  # Message Type (from existing system)
  # ═══════════════════════════════════════════════════════════════════════════

  MessageType* = enum
    mtNone = 0
    mtAppMessage = 1
    mtWindowEvent = 2
    mtViewEvent = 3
    mtServiceRequest = 4
    mtServiceReply = 5
    mtSystemEvent = 6

  Message* = object
    ## BeOS-style message object
    what*: MessageType
    sender*: uint32
    target*: uint32
    timestamp*: uint64
    data*: array[64, uint8]
    dataSize*: uint32

  # ═══════════════════════════════════════════════════════════════════════════
  # High-Performance Port Implementation
  # ═══════════════════════════════════════════════════════════════════════════

  MessagePortArsenal* = object
    ## Lock-free message port using MPMC queue
    ## Multiple producers (threads/processes can post messages)
    ## Multiple consumers (looper can process from multiple ports)
    portId*: uint32
    queue*: KernelMpmcQueue[Message]
    isActive*: bool
    lastMessageTime*: uint64

  LookerArsenal* = object
    ## BeOS-style message looper using high-performance queues
    ## Dispatches messages from multiple ports without blocking
    looperId*: uint32
    ports*: array[16, MessagePortArsenal]
    activePortCount*: uint32
    messageCount*: uint64

# ═══════════════════════════════════════════════════════════════════════════
# Lock-Free Port Operations
# ═══════════════════════════════════════════════════════════════════════════

proc createPortArsenal*(portId: uint32): MessagePortArsenal =
  ## Create lock-free message port
  # Strategy: Initialize MPMC queue for lock-free multi-producer access
  result.portId = portId
  result.queue = initMpmcQueue[Message]()
  result.isActive = true
  result.lastMessageTime = 0

proc postMessageArsenal*(port: var MessagePortArsenal, msg: ptr Message): bool =
  ## Post message to port (lock-free, any producer)
  # Strategy: Enqueue to MPMC queue with compare-and-swap
  # Non-blocking: returns false if queue full (254 messages)
  if msg == nil:
    return false

  let success = enqueueMpmc[Message](port.queue, msg[])
  if success:
    port.lastMessageTime = msg.timestamp
  return success

proc getMessageArsenal*(port: var MessagePortArsenal): Option[Message] =
  ## Get next message from port (lock-free, wait-free)
  # Strategy: Dequeue from MPMC with no busy-wait
  # Returns none if queue empty
  return dequeueMpmc[Message](port.queue)

proc peekMessageArsenal*(port: MessagePortArsenal): Option[Message] =
  ## Peek at next message without removing (lock-free)
  # Strategy: Head pointer read only (no mutation)
  # For MPMC, exact peek requires snapshot; this is approximate
  # TODO: Implement peek for MPMC queues
  return none(Message)

proc messageCountArsenal*(port: MessagePortArsenal): uint32 =
  ## Get pending message count (approximated in MPMC)
  # Strategy: Read atomic count (approximate due to MPMC concurrency)
  # Useful for statistics, not for correctness decisions
  return countMpmc[Message](port.queue)

proc flushPortArsenal*(port: var MessagePortArsenal) =
  ## Drain all pending messages
  # Strategy: Repeated dequeue until empty
  # Used for cleanup or to reset state
  while let msg = getMessageArsenal(port):
    # Message dropped (cleanup)
    discard

# ═══════════════════════════════════════════════════════════════════════════
# High-Performance Looper
# ═══════════════════════════════════════════════════════════════════════════

proc createLookerArsenal*(looperId: uint32): LookerArsenal =
  ## Create looper with multiple lock-free ports
  # Strategy: Initialize array of MPMC ports for lock-free message dispatch
  result.looperId = looperId
  result.activePortCount = 0
  result.messageCount = 0

proc addPortArsenal*(looper: var LookerArsenal, port: MessagePortArsenal): bool =
  ## Add port to looper
  # Strategy: Add to list (no synchronization needed at looper creation time)
  if looper.activePortCount >= 16:
    return false

  looper.ports[looper.activePortCount] = port
  inc looper.activePortCount
  return true

proc dispatchMessageArsenal*(looper: var LookerArsenal, handler: proc(msg: ptr Message)): uint32 =
  ## Dispatch all pending messages from all ports (lock-free)
  # Strategy: Round-robin through ports, process all available messages
  # Returns count of messages processed
  var count = 0'u32

  for i in 0..<looper.activePortCount:
    while let msg = getMessageArsenal(looper.ports[i]):
      var msgCopy = msg
      handler(addr msgCopy)
      inc count
      inc looper.messageCount

  return count

proc processMessageArsenal*(looper: var LookerArsenal, portIdx: uint32, handler: proc(msg: ptr Message)): bool =
  ## Process one message from specific port
  # Strategy: Single dequeue with callback (wait-free)
  if portIdx >= looper.activePortCount:
    return false

  if let msg = getMessageArsenal(looper.ports[portIdx]):
    var msgCopy = msg
    handler(addr msgCopy)
    inc looper.messageCount
    return true

  return false

proc processAllArsenal*(looper: var LookerArsenal, handler: proc(msg: ptr Message)): uint32 =
  ## Process all pending messages (returns count processed)
  # Strategy: Drain all queues completely before returning
  return dispatchMessageArsenal(looper, handler)

# ═══════════════════════════════════════════════════════════════════════════
# Statistics and Monitoring
# ═══════════════════════════════════════════════════════════════════════════

proc totalPendingMessagesArsenal*(looper: LookerArsenal): uint32 =
  ## Get total pending messages across all ports (approximate)
  # Strategy: Sum counts (approximate due to MPMC concurrency)
  var total = 0'u32
  for i in 0..<looper.activePortCount:
    total += messageCountArsenal(looper.ports[i])
  return total

proc portStatisticsArsenal*(port: MessagePortArsenal): string =
  ## Get formatted port statistics
  let pending = messageCountArsenal(port)
  return "Port " & $port.portId & ": " & $pending & " pending, last at tick " & $port.lastMessageTime

proc lookerStatisticsArsenal*(looper: LookerArsenal): string =
  ## Get formatted looper statistics
  var result = "Looper " & $looper.looperId & ":\\n"
  result = result & "  Total messages processed: " & $looper.messageCount & "\\n"
  result = result & "  Active ports: " & $looper.activePortCount & "\\n"
  result = result & "  Pending messages: " & $totalPendingMessagesArsenal(looper) & "\\n"
  return result

# ═══════════════════════════════════════════════════════════════════════════
# Design Notes
# ═══════════════════════════════════════════════════════════════════════════
##
## Comparison with Simple Ring Buffer Implementation:
##
## Simple Ring Buffer (message.nim):
## - Pros: Simple, predictable, easy to reason about
## - Cons: Requires lock for multi-producer, busy-wait on full
##
## Arsenal MPMC Queue:
## - Pros: Lock-free, wait-free on dequeue, multi-producer safe
## - Cons: More CPU cache complexity, internal synchronization overhead
##
## When to use Arsenal version:
## - High message rate (1000+ msgs/sec)
## - Multiple producers (interrupt handlers + threads)
## - Need for true async processing (no spinning)
## - Real-time constraints (bounded latency)
##
## When to use Simple version:
## - Low message rate
## - Single producer, single consumer
## - Simplicity and readability valued over performance
## - Embedded/resource-constrained systems
