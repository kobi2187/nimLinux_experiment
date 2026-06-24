# SPDX-License-Identifier: GPL-2.0
## Dispatcher core logic — CPS run loop, request routing, priority queue.
## Pure: no kernel ABI imports. Inject dependencies via DispatchIface.
## Compiled with --mm:arc --panics:on (required by nim-cps).

import priority_queue
import qos_policy

when not defined(dispatchNoCps):
  import cps
  import dispatch_wire

# ── Injected interface (filled by kmod or server_elf variant) ────────────────

type
  SendFn*  = proc(channel: cstring; data: pointer; len: int): int {.nimcall.}
  RecvFn*  = proc(channel: cstring; buf: pointer; len: int): int {.nimcall.}
  SleepFn* = proc(ticks: uint64) {.nimcall.}
  LogFn*   = proc(msg: cstring) {.nimcall.}

  DispatchIface* = object
    send*:  SendFn
    recv*:  RecvFn
    sleep*: SleepFn
    log*:   LogFn

# ── Continuation type ────────────────────────────────────────────────────────

when not defined(dispatchNoCps):
  type DispatchCont* = ref object of Continuation

# ── Dispatcher state ─────────────────────────────────────────────────────────

type DispatchState* = object
  queue*:    PriorityQueue
  iface*:    DispatchIface
  tickNow*:  uint64
  lastAge*:  uint64        ## last tick we ran applyAging

const DispatchChannel* = "dispatch"
const AgingInterval*   = 50'u64   ## run aging every 50 ticks

proc dispatchInit*(ds: var DispatchState; iface: DispatchIface) =
  pqInit(ds.queue)
  ds.iface   = iface
  ds.tickNow = 0
  ds.lastAge = 0

# ── CPS coroutines (host/kernel only; excluded from --os:standalone ELF build) ─

when not defined(dispatchNoCps):
  proc ingestRequests*(ds: ptr DispatchState) {.cps: DispatchCont.} =
    ## Continuously receive requests from the dispatch channel and enqueue them.
    var buf: array[256, byte]
    while true:
      let n = ds.iface.recv(DispatchChannel, addr buf[0], buf.len)
      if n > 0:
        let wreq = decodeRequest(cast[string](buf.toOpenArray(0, n-1)))
        var req = DispatchRequest(
          op:        wreq.op,
          callerPid: wreq.pid,
          class:     classifyRequest(wreq.op, false),
          deadline:  assignDeadline(classifyRequest(wreq.op, false), ds.tickNow),
          payloadSlot: -1
        )
        discard pqPush(ds.queue, req, ds.tickNow)

  proc dispatchRequests*(ds: ptr DispatchState) {.cps: DispatchCont.} =
    ## Pop highest-priority request and route it to the appropriate server.
    while true:
      var req: DispatchRequest
      if pqPop(ds.queue, req):
        # Route: top byte of op = category (0=fs, 1=net, 2=media, 3=input)
        let category = req.op shr 24
        let target: cstring = case category
          of 0: "fs"
          of 1: "net"
          of 2: "media"
          of 3: "input"
          else: "log"
        # Forward the request to the target server
        let fwd = encodeRequest(req.op, req.callerPid)
        discard ds.iface.send(target, cast[pointer](unsafeAddr fwd[0]), fwd.len)

# ── Tick (called every scheduler quantum) ────────────────────────────────────

proc dispatchTick*(ds: var DispatchState) =
  ## Advance time, run aging if due.
  inc ds.tickNow
  if ds.tickNow - ds.lastAge >= AgingInterval:
    applyAging(ds.queue, ds.tickNow)
    ds.lastAge = ds.tickNow
