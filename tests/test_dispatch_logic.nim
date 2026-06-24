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

echo "All dispatch_logic tests passed."
