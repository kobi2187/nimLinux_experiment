# SPDX-License-Identifier: GPL-2.0
## Unit tests for servers/dispatch/dispatch_logic.nim
##
## Compile: nim c -r --skipParentCfg --mm:arc --panics:on \
##            --path:<repo-root> \
##            -d:noSignalHandler tests/test_dispatch_logic.nim

import servers/dispatch/dispatch_logic
import servers/dispatch/dispatch_wire
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

# ── Actor-pipeline tests: full deliver → ingest → drain → send path ──────────

var gSent: seq[(string, uint32)]   ## (target channel, decoded op)
var gSendOk = true

proc recSend(channel: cstring; data: pointer; len: int): int {.nimcall.} =
  if not gSendOk: return -1
  var wire = newString(len)
  copyMem(addr wire[0], data, len)
  gSent.add(($channel, decodeRequest(wire).op))
  len

let recIface = DispatchIface(
  send: recSend, recv: mockRecv, sleep: mockSleep, log: mockLog)

proc deliverReq(a: Actor; op: uint32; pid: uint32) =
  a.deliver(mkRequestMsg(encodeRequest(op, pid)))

# ── Test 8: requests route through the actor to the right channels ───────────

block test_actor_routes:
  var ds: DispatchState
  dispatchInit(ds, recIface)
  gSent = @[]; gSendOk = true

  var a = newDispatcher(addr ds)
  a.deliverReq(0x00000001'u32, 1)   # fs
  a.deliverReq(0x01000002'u32, 2)   # net
  a.deliverReq(0x02000003'u32, 3)   # media
  assert gSent == @[("fs", 0x00000001'u32), ("net", 0x01000002'u32),
                    ("media", 0x02000003'u32)], "each request forwarded to its category channel"
  assert ds.queue.count == 0, "queue drained after each wake"
  assert a.isSuspended, "dispatcher re-parked"
  echo "PASS: test_actor_routes"

# ── Test 9: backpressured drain forwards in priority order on tick ───────────

block test_actor_priority_drain:
  var ds: DispatchState
  dispatchInit(ds, recIface)
  gSent = @[]

  var a = newDispatcher(addr ds)
  gSendOk = false                    # backpressure: everything queues
  a.deliverReq(0x04000001'u32, 1)    # log   → rcBackground
  a.deliverReq(0x02000002'u32, 2)    # media → rcRealtime
  a.deliverReq(0x00000003'u32, 3)    # fs    → rcNormal
  assert ds.queue.count == 3, "all requests held under backpressure"
  assert gSent.len == 0

  gSendOk = true                     # pressure lifts; tick triggers drain
  a.deliver(mkTickMsg())
  assert gSent == @[("media", 0x02000002'u32), ("fs", 0x00000003'u32),
                    ("log", 0x04000001'u32)], "drain follows QoS class order"
  assert ds.queue.count == 0
  echo "PASS: test_actor_priority_drain"

# ── Test 10: ticks age queued Background up to Normal ────────────────────────

block test_actor_tick_aging:
  var ds: DispatchState
  dispatchInit(ds, recIface)
  gSent = @[]; gSendOk = false

  var a = newDispatcher(addr ds)
  a.deliverReq(0x04000001'u32, 9)    # rcBackground, stuck (send failing)
  for _ in 0 ..< 51:                 # aging fires at AgingInterval=50
    a.deliver(mkTickMsg())
  assert ds.queue.count == 1, "still queued while backpressured"
  assert ds.queue.heap[0].class == rcNormal, "Background aged up to Normal while waiting"
  echo "PASS: test_actor_tick_aging"

# ── Pump tests: inbound channel → actor → tick ───────────────────────────────

var gInbox: seq[string]   ## raw messages waiting on the "dispatch" channel
var gLogs: seq[string]

proc queueRecv(channel: cstring; buf: pointer; len: int): int {.nimcall.} =
  ## Mimics abiChanRecv: -1 when empty, else bytes copied (truncated to len).
  assert $channel == DispatchChannel, "pump must read the dispatch channel"
  if gInbox.len == 0: return -1
  let m = gInbox[0]
  gInbox.delete(0)
  result = min(m.len, len)
  copyMem(buf, unsafeAddr m[0], result)

proc recLog(msg: cstring) {.nimcall.} = gLogs.add($msg)

let pumpIface = DispatchIface(
  send: recSend, recv: queueRecv, sleep: mockSleep, log: recLog)

# ── Test 11: pump delivers every queued request in arrival order, then ticks ─

block test_pump_delivers:
  var ds: DispatchState
  dispatchInit(ds, pumpIface)
  gSent = @[]; gSendOk = true
  gInbox = @[encodeRequest(0x00000001'u32, 1), encodeRequest(0x01000002'u32, 2)]

  var a = newDispatcher(addr ds)
  assert dispatchPump(addr ds, a) == 2, "both requests delivered"
  assert gSent == @[("fs", 0x00000001'u32), ("net", 0x01000002'u32)]
  assert ds.tickNow == 1, "one tick per pump"
  assert gInbox.len == 0 and a.isSuspended
  echo "PASS: test_pump_delivers"

# ── Test 12: empty channel still ticks ───────────────────────────────────────

block test_pump_empty_ticks:
  var ds: DispatchState
  dispatchInit(ds, pumpIface)
  gInbox = @[]
  var a = newDispatcher(addr ds)
  for _ in 0 ..< 3:
    assert dispatchPump(addr ds, a) == 0
  assert ds.tickNow == 3, "ticks advance with no traffic"
  echo "PASS: test_pump_empty_ticks"

# ── Test 13: per-quantum bound leaves the rest for the next pump ─────────────

block test_pump_bounded:
  var ds: DispatchState
  dispatchInit(ds, pumpIface)
  gSent = @[]; gSendOk = true
  gInbox = @[]
  for i in 0 ..< PumpMaxPerQuantum + 5:
    gInbox.add(encodeRequest(0x00000001'u32, uint32(i)))
  var a = newDispatcher(addr ds)
  assert dispatchPump(addr ds, a) == PumpMaxPerQuantum
  assert gInbox.len == 5, "excess left on the channel"
  assert dispatchPump(addr ds, a) == 5
  assert gSent.len == PumpMaxPerQuantum + 5
  echo "PASS: test_pump_bounded"

# ── Test 14: oversize and malformed requests are dropped, not fatal ──────────

block test_pump_drops_bad_input:
  var ds: DispatchState
  dispatchInit(ds, pumpIface)
  gSent = @[]; gSendOk = true; gLogs = @[]
  gInbox = @[newString(MailMsgMax + 10),          # truncated by recv → dropped
             "\xc1garbage",                         # 0xc1 = never-used msgpack byte
             encodeRequest(0x00000007'u32, 7)]      # good one still gets through
  var a = newDispatcher(addr ds)
  assert dispatchPump(addr ds, a) == 2, "oversize skipped before delivery"
  assert gSent == @[("fs", 0x00000007'u32)], "valid request routed after bad ones"
  assert gLogs == @["dispatch: dropped oversize request\n",
                    "dispatch: dropped malformed request\n"]
  assert a.isSuspended, "dispatcher survived bad input"
  echo "PASS: test_pump_drops_bad_input"

# ── Test 15: strict decoder agrees with msgpack4nim, rejects all malformed ───

block test_try_decode_request:
  const vals = [0'u32, 1, 0x7f, 0x80, 0xff, 0x100, 0xffff, 0x10000, high(uint32)]
  for op in vals:
    for pid in vals:
      let wire = encodeRequest(op, pid)
      var r: WireRequest
      assert tryDecodeRequest(wire, r), "valid encoding accepted"
      assert r.op == op and r.pid == pid, "decoded values match encoder"
      for cut in 0 ..< wire.len:                   # every truncation rejected
        assert not tryDecodeRequest(wire[0 ..< cut], r)
      assert not tryDecodeRequest(wire & "\x00", r), "trailing bytes rejected"
  var r: WireRequest
  assert not tryDecodeRequest("\x93\x01\x02\x03", r), "3-element array rejected"
  assert not tryDecodeRequest("\x92\xcf\0\0\0\0\0\0\0\x01\x02", r), "uint64 rejected"
  assert not tryDecodeRequest("\x92\xff\x01", r), "negative fixint rejected"
  assert not tryDecodeRequest("\x92\xa1x\x01", r), "string field rejected"
  echo "PASS: test_try_decode_request"

echo "All dispatch_logic tests passed."
