# SPDX-License-Identifier: GPL-2.0
## Inter-Process Communication (IPC)
##
## Supports multiple IPC mechanisms:
## - Message passing (queues)
## - Shared memory
## - Semaphores
## - Signal handling

import ../core/types

type
  # ═══════════════════════════════════════════════════════════════════════════
  # IPC Types
  # ═══════════════════════════════════════════════════════════════════════════

  IpcMessageType* = enum
    imtRequest = 0
    imtReply = 1
    imtNotification = 2
    imtSignal = 3

  IpcMessage* = object
    ## Generic IPC message
    sender*: uint32        ## Sender PID
    receiver*: uint32      ## Receiver PID
    msgType*: IpcMessageType
    msgId*: uint32
    payloadSize*: uint32
    payload*: array[256, uint8]

  MessageQueue* = object
    ## FIFO message queue for process communication
    messages*: array[64, IpcMessage]
    head*: uint8
    tail*: uint8
    count*: uint8

  SharedMemorySegment* = object
    ## Shared memory region
    segmentId*: uint32
    address*: VirtAddr
    size*: uint64
    permissions*: uint16   ## Read/write flags per process
    refCount*: uint32

  SemaphoreType* = enum
    stBinary = 0           ## Binary semaphore (mutex)
    stCounting = 1         ## Counting semaphore

  Semaphore* = object
    ## Synchronization primitive
    semId*: uint32
    semType*: SemaphoreType
    value*: uint32
    waitQueue*: array[16, uint32]  ## PIDs waiting on this semaphore
    waitCount*: uint8

  Signal* = enum
    ## POSIX signals
    sigTerm = 15
    sigKill = 9
    sigStop = 19
    sigCont = 18
    sigChld = 17
    sigAbrt = 6
    sigAlrm = 14
    sigUsr1 = 10
    sigUsr2 = 12

  SignalAction* = object
    ## Signal handler
    handler*: proc(sig: Signal) {.cdecl.}
    mask*: uint64          ## Blocked signals while handler runs
    flags*: uint16

# ═══════════════════════════════════════════════════════════════════════════
# Message Queue Operations
# ═══════════════════════════════════════════════════════════════════════════

proc initMessageQueue*(queue: var MessageQueue) =
  ## Initialize empty message queue
  queue.head = 0
  queue.tail = 0
  queue.count = 0

proc enqueueMessage*(queue: var MessageQueue, msg: IpcMessage): bool =
  ## Add message to queue (returns false if full)
  if queue.count >= 64:
    return false
  queue.messages[queue.tail] = msg
  queue.tail = (queue.tail + 1) mod 64
  inc queue.count
  return true

proc dequeueMessage*(queue: var MessageQueue): IpcMessage =
  ## Remove and return message from queue
  result = queue.messages[queue.head]
  queue.head = (queue.head + 1) mod 64
  if queue.count > 0:
    dec queue.count

proc peekMessage*(queue: MessageQueue): IpcMessage =
  ## Peek at next message without removing it
  if queue.count > 0:
    return queue.messages[queue.head]
  result = IpcMessage()

proc messageQueueLength*(queue: MessageQueue): uint8 =
  ## Get number of messages in queue
  return queue.count

proc messageQueueIsFull*(queue: MessageQueue): bool =
  ## Check if queue is full
  return queue.count >= 64

proc messageQueueIsEmpty*(queue: MessageQueue): bool =
  ## Check if queue is empty
  return queue.count == 0

# ═══════════════════════════════════════════════════════════════════════════
# Shared Memory Operations
# ═══════════════════════════════════════════════════════════════════════════

proc createSharedMemory*(size: uint64, permissions: uint16): SharedMemorySegment =
  ## Create a new shared memory segment
  result.segmentId = 0  # Would be assigned by IPC manager
  result.size = size
  result.permissions = permissions
  result.refCount = 1

proc attachSharedMemory*(segment: var SharedMemorySegment, addr: VirtAddr) =
  ## Attach shared memory to process address space
  segment.address = addr
  inc segment.refCount

proc detachSharedMemory*(segment: var SharedMemorySegment) =
  ## Detach shared memory from process
  if segment.refCount > 0:
    dec segment.refCount

proc deleteSharedMemory*(segment: var SharedMemorySegment) =
  ## Delete shared memory segment (when refCount reaches 0)
  if segment.refCount == 0:
    # Would free the memory
    discard

# ═══════════════════════════════════════════════════════════════════════════
# Semaphore Operations
# ═══════════════════════════════════════════════════════════════════════════

proc createSemaphore*(semType: SemaphoreType, initialValue: uint32): Semaphore =
  ## Create a new semaphore
  result.semType = semType
  result.value = initialValue
  result.waitCount = 0

proc semaphoreWait*(sem: var Semaphore, pid: uint32): bool =
  ## Wait on semaphore (decrement if possible, else block)
  if sem.value > 0:
    dec sem.value
    return true
  # Would block process here
  if sem.waitCount < 16:
    sem.waitQueue[sem.waitCount] = pid
    inc sem.waitCount
  return false

proc semaphorePost*(sem: var Semaphore): bool =
  ## Signal semaphore (increment and wake waiter if any)
  inc sem.value
  if sem.waitCount > 0:
    # Would wake the first waiting process
    for i in 0..<sem.waitCount - 1:
      sem.waitQueue[i] = sem.waitQueue[i + 1]
    dec sem.waitCount
    return true
  return false

proc semaphoreValue*(sem: Semaphore): uint32 =
  ## Get current semaphore value
  return sem.value

proc semaphoreWaiters*(sem: Semaphore): uint8 =
  ## Get number of processes waiting on semaphore
  return sem.waitCount

# ═══════════════════════════════════════════════════════════════════════════
# Signal Operations
# ═══════════════════════════════════════════════════════════════════════════

var gSignalHandlers*: array[32, SignalAction]

proc registerSignalHandler*(sig: Signal, action: SignalAction) =
  ## Register handler for a signal
  gSignalHandlers[ord(sig)] = action

proc sendSignal*(targetPid: uint32, sig: Signal) =
  ## Send signal to another process
  # Would look up target process and deliver signal
  discard

proc getCurrentSignalMask*(): uint64 =
  ## Get currently blocked signals
  # Would return mask from current process
  0

proc setSignalMask*(mask: uint64) =
  ## Set signal mask (block signals)
  discard

proc getSignalHandler*(sig: Signal): SignalAction =
  ## Get handler for signal
  return gSignalHandlers[ord(sig)]

# ═══════════════════════════════════════════════════════════════════════════
# Global IPC Manager
# ═══════════════════════════════════════════════════════════════════════════

const
  MaxMessageQueues* = 256
  MaxSharedSegments* = 64
  MaxSemaphores* = 128

var
  gMessageQueues*: array[MaxMessageQueues, MessageQueue]
  gSharedSegments*: array[MaxSharedSegments, SharedMemorySegment]
  gSemaphores*: array[MaxSemaphores, Semaphore]

proc initIpc*() =
  ## Initialize IPC subsystem
  for i in 0..<MaxMessageQueues:
    initMessageQueue(gMessageQueues[i])
  for i in 0..<MaxSemaphores:
    gSemaphores[i] = createSemaphore(stCounting, 0)

proc getMessageQueue*(queueId: uint32): ptr MessageQueue =
  ## Get message queue by ID
  if queueId < MaxMessageQueues:
    return addr gMessageQueues[queueId]
  return nil

proc getSemaphore*(semId: uint32): ptr Semaphore =
  ## Get semaphore by ID
  if semId < MaxSemaphores:
    return addr gSemaphores[semId]
  return nil

proc sendMessage*(fromPid: uint32, toPid: uint32, msg: IpcMessage): bool =
  ## Send message from one process to another
  # Would route message through system message queues
  return true

proc receiveMessage*(pid: uint32): IpcMessage =
  ## Receive message for a process
  # Would pull from process's message queue
  return IpcMessage()

proc sendSignalToProcess*(targetPid: uint32, sig: Signal) =
  ## Deliver signal to process
  discard

proc ipcStats*(): string =
  ## Return formatted IPC statistics
  "IPC: " & $MaxMessageQueues & " queues, " &
  $MaxSharedSegments & " segments, " &
  $MaxSemaphores & " semaphores"
