# SPDX-License-Identifier: GPL-2.0
## QoS policy engine — classifies requests and applies aging.

import priority_queue

const
  AgingThresholdTicks* = 50   ## 500ms at 100Hz — bump class after this wait
  DeadlineRealtime*    = 5'u64   ## ticks
  DeadlineInteractive* = 16'u64
  DeadlineNormal*      = 100'u64

proc classifyRequest*(op: uint32; callerIsServer: bool): RequestClass =
  ## Assign initial priority class based on operation type and caller.
  ## op high byte: 0=fs, 1=net, 2=media, 3=input, 4=log, 5=system
  let category = op shr 24
  case category
  of 2: rcRealtime    ## media ops always realtime
  of 3: rcInteractive ## input ops interactive
  of 4: rcBackground  ## log ops background
  else:
    if callerIsServer: rcNormal else: rcNormal

proc assignDeadline*(class: RequestClass; nowTick: uint64): uint64 =
  case class
  of rcRealtime:    nowTick + DeadlineRealtime
  of rcInteractive: nowTick + DeadlineInteractive
  of rcNormal:      nowTick + DeadlineNormal
  of rcBackground:  0  ## no deadline

proc applyAging*(pq: var PriorityQueue; nowTick: uint64) =
  ## Walk queue, bump class of any request waiting too long.
  ## O(n) but called infrequently (every AgingThresholdTicks).
  for i in 0 ..< pq.count:
    let waited = nowTick - pq.heap[i].arrivalTick
    if waited >= AgingThresholdTicks and pq.heap[i].class != rcRealtime:
      pq.heap[i].class = RequestClass(int(pq.heap[i].class) - 1)
  # Re-heapify after in-place modifications (simple O(n) build)
  for i in countdown(pq.count div 2 - 1, 0):
    var j = i
    while true:
      let l = 2*j+1; let r = 2*j+2
      var best = j
      if l < pq.count and pqLess(pq.heap[l], pq.heap[best]): best = l
      if r < pq.count and pqLess(pq.heap[r], pq.heap[best]): best = r
      if best == j: break
      swap(pq.heap[j], pq.heap[best]); j = best
