# SPDX-License-Identifier: GPL-2.0
## Dispatcher priority queue — min-heap keyed on (class, deadline, arrival).
## Pure logic, no kernel deps, host-testable.

const MaxQueueSize* = 256

type
  RequestClass* = enum
    rcRealtime    = 0  ## audio, media decode  — < 5ms latency budget
    rcInteractive = 1  ## GUI, key input        — < 16ms
    rcNormal      = 2  ## file open, network   — < 100ms
    rcBackground  = 3  ## downloads, indexing  — best-effort

  DispatchRequest* = object
    id*:          uint64       ## monotonic request ID
    class*:       RequestClass
    deadline*:    uint64       ## absolute tick deadline (0 = none)
    arrivalTick*: uint64       ## when request was enqueued
    callerPid*:   uint32
    op*:          uint32       ## operation code (fs.read, net.send, etc.)
    payloadSlot*: int          ## region slot for bulk data (-1 = none)

  PriorityQueue* = object
    heap*:  array[MaxQueueSize, DispatchRequest]
    count*: int
    nextId: uint64

proc pqInit*(pq: var PriorityQueue) =
  pq.count  = 0
  pq.nextId = 1

proc pqLess*(a, b: DispatchRequest): bool =
  ## Lower class value = higher priority. Tie-break on deadline then arrival.
  if a.class != b.class: return int(a.class) < int(b.class)
  if a.deadline != b.deadline and a.deadline != 0 and b.deadline != 0:
    return a.deadline < b.deadline
  return a.arrivalTick < b.arrivalTick

proc pqPush*(pq: var PriorityQueue; req: var DispatchRequest; nowTick: uint64): bool =
  ## Enqueue a request. Returns false if queue full.
  if pq.count >= MaxQueueSize: return false
  req.id          = pq.nextId; inc pq.nextId
  req.arrivalTick = nowTick
  pq.heap[pq.count] = req
  # Sift up
  var i = pq.count; inc pq.count
  while i > 0:
    let parent = (i - 1) div 2
    if pqLess(pq.heap[i], pq.heap[parent]):
      swap(pq.heap[i], pq.heap[parent])
      i = parent
    else: break
  true

proc pqPop*(pq: var PriorityQueue; req: var DispatchRequest): bool =
  ## Dequeue highest-priority request. Returns false if empty.
  if pq.count == 0: return false
  req = pq.heap[0]
  dec pq.count
  if pq.count > 0:
    pq.heap[0] = pq.heap[pq.count]
    # Sift down
    var i = 0
    while true:
      let l = 2*i+1; let r = 2*i+2
      var best = i
      if l < pq.count and pqLess(pq.heap[l], pq.heap[best]): best = l
      if r < pq.count and pqLess(pq.heap[r], pq.heap[best]): best = r
      if best == i: break
      swap(pq.heap[i], pq.heap[best]); i = best
  true

proc pqPeek*(pq: PriorityQueue): ptr DispatchRequest =
  if pq.count == 0: return nil
  unsafeAddr pq.heap[0]
