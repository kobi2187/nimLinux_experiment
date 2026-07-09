# SPDX-License-Identifier: GPL-2.0
## Host-side test for MPSC Lock-free Queue.
{.experimental: "parallel".}
import ipc/mpsc_ring
import unittest
import std/threadpool
import std/locks

suite "MPSC Lock-Free Queue":
  test "Basic single-threaded FIFO":
    var q: MpscQueue[4, int]
    mpscInit(q)
    
    check mpscEnqueue(q, 10)
    check mpscEnqueue(q, 20)
    check mpscCount(q) == 2
    
    var val = 0
    check mpscDequeue(q, val)
    check val == 10
    
    check mpscDequeue(q, val)
    check val == 20
    
    check mpscIsEmpty(q)

  test "Capacity bounds and full-state check":
    var q: MpscQueue[2, int]
    mpscInit(q)
    
    check mpscEnqueue(q, 1)
    check mpscEnqueue(q, 2)
    check not mpscEnqueue(q, 3) # Full
    
    var val = 0
    check mpscDequeue(q, val)
    check val == 1
    
    check mpscEnqueue(q, 3) # Space freed
    
    check mpscDequeue(q, val)
    check val == 2
    check mpscDequeue(q, val)
    check val == 3
    check not mpscDequeue(q, val) # Empty

  test "Parallel producers writing concurrently":
    var q: MpscQueue[64, int]
    mpscInit(q)
    
    # Spawn 4 threads writing 10 integers each
    parallel:
      spawn (proc() =
        for i in 1..10:
          while not mpscEnqueue(q, 100 + i): discard
      )()
      spawn (proc() =
        for i in 1..10:
          while not mpscEnqueue(q, 200 + i): discard
      )()
      spawn (proc() =
        for i in 1..10:
          while not mpscEnqueue(q, 300 + i): discard
      )()
      spawn (proc() =
        for i in 1..10:
          while not mpscEnqueue(q, 400 + i): discard
      )()
      
    # Dequeue and verify counts
    sync()
    
    var counts: array[5, int]
    var val = 0
    while mpscDequeue(q, val):
      let category = val div 100
      if category >= 1 and category <= 4:
        inc counts[category]
        
    check counts[1] == 10
    check counts[2] == 10
    check counts[3] == 10
    check counts[4] == 10
