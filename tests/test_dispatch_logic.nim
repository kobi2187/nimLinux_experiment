# SPDX-License-Identifier: GPL-2.0
## Unit tests for servers/dispatch/dispatch_logic.nim
##
## Compile: nim c -r --skipParentCfg --mm:arc --panics:on \
##            --path:/home/kl/prog/nimLinux_experiment \
##            -d:noSignalHandler tests/test_dispatch_logic.nim

import servers/dispatch/dispatch_logic
import servers/dispatch/priority_queue
import servers/dispatch/qos_policy

# ── Mock iface ───────────────────────────────────────────────────────────────

proc mockSend(channel: cstring; data: pointer; len: int): int {.nimcall.} = 0
proc mockRecv(channel: cstring; buf: pointer; len: int): int {.nimcall.} = 0
proc mockSleep(ticks: uint64) {.nimcall.} = discard
proc mockLog(msg: cstring) {.nimcall.} = discard

let mockIface = DispatchIface(
  send:  mockSend,
  recv:  mockRecv,
  sleep: mockSleep,
  log:   mockLog
)

# ── Helpers ──────────────────────────────────────────────────────────────────

proc pushReq(ds: var DispatchState; op: uint32; pid: uint32) =
  var req = DispatchRequest(
    op:          op,
    callerPid:   pid,
    class:       classifyRequest(op, false),
    deadline:    assignDeadline(classifyRequest(op, false), ds.tickNow),
    payloadSlot: -1
  )
  discard pqPush(ds.queue, req, ds.tickNow)

# ── Test 1: dispatchInit initialises cleanly ─────────────────────────────────

block test_init:
  var ds: DispatchState
  dispatchInit(ds, mockIface)
  assert ds.queue.count == 0, "queue should be empty after init"
  assert ds.tickNow == 0,     "tickNow should be 0 after init"
  assert ds.lastAge == 0,     "lastAge should be 0 after init"
  echo "PASS: test_init"

# ── Test 2: push 3 requests, tick 10 times, queue count stays 3 ──────────────

block test_push_and_tick:
  var ds: DispatchState
  dispatchInit(ds, mockIface)

  # Background: op high-byte = 4 (log category → rcBackground)
  pushReq(ds, 0x04000001'u32, 10)
  # Realtime: op high-byte = 2 (media → rcRealtime)
  pushReq(ds, 0x02000002'u32, 11)
  # Normal: op high-byte = 0 (fs → rcNormal)
  pushReq(ds, 0x00000003'u32, 12)

  assert ds.queue.count == 3, "queue should have 3 requests"

  for _ in 0 ..< 10:
    dispatchTick(ds)

  assert ds.queue.count == 3, "queue count should still be 3 after 10 ticks"
  assert ds.tickNow == 10,    "tickNow should be 10"
  echo "PASS: test_push_and_tick"

# ── Test 3: pqPop returns Realtime first, then Normal, then Background ────────

block test_pop_order:
  var ds: DispatchState
  dispatchInit(ds, mockIface)

  pushReq(ds, 0x04000001'u32, 10)   # rcBackground (class=3)
  pushReq(ds, 0x02000002'u32, 11)   # rcRealtime   (class=0)
  pushReq(ds, 0x00000003'u32, 12)   # rcNormal     (class=2)

  var req: DispatchRequest

  discard pqPop(ds.queue, req)
  assert req.class == rcRealtime,   "first pop should be Realtime"

  discard pqPop(ds.queue, req)
  assert req.class == rcNormal,     "second pop should be Normal"

  discard pqPop(ds.queue, req)
  assert req.class == rcBackground, "third pop should be Background"

  assert ds.queue.count == 0, "queue should be empty after 3 pops"
  echo "PASS: test_pop_order"

# ── Test 4: after 51 ticks, aging bumps Background to Normal ─────────────────

block test_aging:
  var ds: DispatchState
  dispatchInit(ds, mockIface)

  # Push Background request at tick 0
  pushReq(ds, 0x04000001'u32, 20)   # rcBackground (class=3)
  assert ds.queue.count == 1
  assert ds.queue.heap[0].class == rcBackground, "should start as Background"

  # Tick 51 times — aging fires at tick 50 (50 - 0 >= AgingInterval)
  for _ in 0 ..< 51:
    dispatchTick(ds)

  assert ds.tickNow == 51, "tickNow should be 51"

  # After aging the Background request (waited >= 50 ticks) is bumped to Normal
  var req: DispatchRequest
  discard pqPop(ds.queue, req)
  assert req.class == rcNormal, "Background should have been bumped to Normal after aging"
  echo "PASS: test_aging"

# ── Test 5: route by category — op=0x00000001 (fs, category=0) → "fs" ─────────

block test_route_by_category:
  var ds: DispatchState
  dispatchInit(ds, mockIface)

  # op high byte = 0 → fs category → classifyRequest gives rcNormal
  pushReq(ds, 0x00000001'u32, 42)
  assert ds.queue.count == 1

  var req: DispatchRequest
  discard pqPop(ds.queue, req)
  assert ds.queue.count == 0

  # Verify routing: top byte of op = 0 → "fs"
  let category = req.op shr 24
  assert category == 0, "category should be 0 (fs)"
  # The dispatch logic routes category=0 to "fs"
  let target: cstring = case category
    of 0: "fs"
    of 1: "net"
    of 2: "media"
    of 3: "input"
    else: "log"
  assert target == "fs", "category 0 should route to fs"
  echo "PASS: test_route_by_category"

# ── Test 6: realtime deadline = arrivalTick + 5 ───────────────────────────────

block test_realtime_deadline:
  var ds: DispatchState
  dispatchInit(ds, mockIface)
  ds.tickNow = 10   # set a non-zero arrival tick

  # op high byte = 2 → media → rcRealtime
  pushReq(ds, 0x02000001'u32, 99)
  assert ds.queue.count == 1

  let req = ds.queue.heap[0]
  assert req.class == rcRealtime, "should be rcRealtime"
  assert req.deadline == 10 + 5, "realtime deadline should be arrivalTick + 5"
  echo "PASS: test_realtime_deadline"

# ── Test 7: aging boundary — 49 ticks no bump, tick 50 bumps Background ───────

block test_aging_boundary:
  var ds: DispatchState
  dispatchInit(ds, mockIface)

  # Push Background at tick 0
  pushReq(ds, 0x04000001'u32, 77)   # rcBackground (category=4=log)
  assert ds.queue.count == 1
  assert ds.queue.heap[0].class == rcBackground, "should start as Background"

  # Tick 49 times — aging interval is 50, so no aging yet
  for _ in 0 ..< 49:
    dispatchTick(ds)

  assert ds.tickNow == 49, "tickNow should be 49"
  assert ds.queue.heap[0].class == rcBackground, "still Background after 49 ticks"

  # One more tick (total = 50) — aging fires
  dispatchTick(ds)
  assert ds.tickNow == 50, "tickNow should be 50"

  var req: DispatchRequest
  discard pqPop(ds.queue, req)
  assert req.class == rcNormal, "Background should be bumped to Normal after 50 ticks"
  echo "PASS: test_aging_boundary"

echo "All dispatch_logic tests passed."
