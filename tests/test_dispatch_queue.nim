import ../servers/dispatch/priority_queue
import ../servers/dispatch/qos_policy

proc makeReq(class: RequestClass; deadline: uint64 = 0): DispatchRequest =
  result.class    = class
  result.deadline = deadline

template check(cond: bool; msg: string) =
  if not cond:
    echo "FAIL: ", msg
    quit(1)

# Test 1: Basic priority order — Realtime > Normal > Background
block:
  var pq: PriorityQueue
  pqInit(pq)
  var bg = makeReq(rcBackground)
  var rt = makeReq(rcRealtime)
  var nm = makeReq(rcNormal)
  discard pqPush(pq, bg, 0)
  discard pqPush(pq, rt, 1)
  discard pqPush(pq, nm, 2)
  var r: DispatchRequest
  discard pqPop(pq, r); check r.class == rcRealtime,    "test1: first pop should be Realtime"
  discard pqPop(pq, r); check r.class == rcNormal,      "test1: second pop should be Normal"
  discard pqPop(pq, r); check r.class == rcBackground,  "test1: third pop should be Background"
  echo "test1 PASS: basic priority order"

# Test 2: Same class, earlier arrival first
block:
  var pq: PriorityQueue
  pqInit(pq)
  var a = makeReq(rcNormal)
  var b = makeReq(rcNormal)
  discard pqPush(pq, a, 10)
  discard pqPush(pq, b, 20)
  var r: DispatchRequest
  discard pqPop(pq, r); check r.arrivalTick == 10, "test2: earlier arrival should pop first"
  discard pqPop(pq, r); check r.arrivalTick == 20, "test2: later arrival pops second"
  echo "test2 PASS: arrival tie-break"

# Test 3: Aging bumps Background to Normal
block:
  var pq: PriorityQueue
  pqInit(pq)
  for i in 0 ..< 5:
    var req = makeReq(rcBackground)
    discard pqPush(pq, req, 0)
  applyAging(pq, 100)  # waited 100 >= AgingThresholdTicks(50)
  for i in 0 ..< pq.count:
    check pq.heap[i].class == rcNormal, "test3: Background should be bumped to Normal"
  echo "test3 PASS: aging bumps Background -> Normal"

# Test 4: Queue full — MaxQueueSize+1 push returns false
block:
  var pq: PriorityQueue
  pqInit(pq)
  for i in 0 ..< MaxQueueSize:
    var req = makeReq(rcNormal)
    let ok = pqPush(pq, req, uint64(i))
    check ok, "test4: push " & $i & " should succeed"
  var extra = makeReq(rcNormal)
  let overflow = pqPush(pq, extra, uint64(MaxQueueSize))
  check not overflow, "test4: push beyond MaxQueueSize should return false"
  echo "test4 PASS: queue full returns false"

# Test 5: Pop from empty returns false
block:
  var pq: PriorityQueue
  pqInit(pq)
  var r: DispatchRequest
  let ok = pqPop(pq, r)
  check not ok, "test5: pop from empty should return false"
  echo "test5 PASS: empty pop returns false"

# Test 6: Deadline tie-break within same class
block:
  var pq: PriorityQueue
  pqInit(pq)
  var a = makeReq(rcRealtime, deadline = 100)
  var b = makeReq(rcRealtime, deadline = 50)
  discard pqPush(pq, a, 0)
  discard pqPush(pq, b, 1)
  var r: DispatchRequest
  discard pqPop(pq, r); check r.deadline == 50,  "test6: earlier deadline should pop first"
  discard pqPop(pq, r); check r.deadline == 100, "test6: later deadline pops second"
  echo "test6 PASS: deadline tie-break"

echo "=== All dispatch queue tests passed ==="
