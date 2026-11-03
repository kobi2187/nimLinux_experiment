# SPDX-License-Identifier: GPL-2.0
## Dispatcher core logic — CPS run loop, request routing, priority queue.
## Pure: no kernel ABI imports. Inject dependencies via DispatchIface.
## Compiled with --mm:arc --panics:on (required by nim-cps).

import priority_queue
import qos_policy

when not defined(dispatchNoCps):
  import cps
  import dispatch_wire
  import ../../runtime/actor
  import ../../ipc/mailbox
  export actor, mailbox

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

# ── Tick (called every scheduler quantum) ────────────────────────────────────

proc dispatchTick*(ds: var DispatchState) =
  ## Advance time, run aging if due.
  inc ds.tickNow
  if ds.tickNow - ds.lastAge >= AgingInterval:
    applyAging(ds.queue, ds.tickNow)
    ds.lastAge = ds.tickNow

# ── Dispatcher actor (-d:dispatchNoCps omits it for builds without nim-cps) ──
#
# One long-lived actor is the whole run loop. The transport delivers a MailMsg
# per event (request arrived / scheduler tick); the actor ingests, then drains
# the priority queue. Priority ordering matters exactly when draining is
# blocked (send backpressure) — a failed send requeues and waits for the next
# wake, and queued requests age up per QoS policy.

when not defined(dispatchNoCps):
  const
    MsgKindRequest* = 0'u8   ## data[1..] = MsgPack-encoded WireRequest
    MsgKindTick*    = 1'u8   ## no payload

  proc mkRequestMsg*(wire: string): MailMsg =
    ## Wrap an encoded WireRequest for delivery to the dispatcher actor.
    assert wire.len >= 1 and wire.len < MailMsgMax, "wire request must fit a MailMsg"
    result.data[0] = MsgKindRequest
    copyMem(addr result.data[1], unsafeAddr wire[0], wire.len)
    result.len = uint16(wire.len + 1)

  proc mkTickMsg*(): MailMsg =
    result.data[0] = MsgKindTick
    result.len = 1

  proc ingest(ds: ptr DispatchState; msg: MailMsg) =
    ## Decode a request message, classify it, enqueue it.
    ## Malformed wire bytes come from untrusted apps: drop and log, never die.
    var wire = newString(int(msg.len) - 1)
    copyMem(addr wire[0], unsafeAddr msg.data[1], wire.len)
    var wreq: WireRequest
    if not tryDecodeRequest(wire, wreq):
      ds.iface.log("dispatch: dropped malformed request\n")
      return
    let class = classifyRequest(wreq.op, false)
    var req = DispatchRequest(
      op:          wreq.op,
      callerPid:   wreq.pid,
      class:       class,
      deadline:    assignDeadline(class, ds.tickNow),
      payloadSlot: -1
    )
    discard pqPush(ds.queue, req, ds.tickNow)

  proc routeTarget(op: uint32): cstring =
    ## Top byte of op = category (0=fs, 1=net, 2=media, 3=input).
    case op shr 24
    of 0'u32: "fs"
    of 1'u32: "net"
    of 2'u32: "media"
    of 3'u32: "input"
    else: "log"

  proc route(ds: ptr DispatchState; req: DispatchRequest): bool =
    ## Forward one request to its target server. False on send failure.
    let fwd = encodeRequest(req.op, req.callerPid)
    ds.iface.send(routeTarget(req.op), cast[pointer](unsafeAddr fwd[0]), fwd.len) >= 0

  proc drain(ds: ptr DispatchState) =
    ## Forward queued requests in priority order until empty or backpressured.
    ## Peek-then-pop: a backpressured request stays queued with its original
    ## arrivalTick, so the aging clock keeps running while it waits.
    while ds.queue.count > 0:
      if not route(ds, pqPeek(ds.queue)[]):
        break
      var req: DispatchRequest
      discard pqPop(ds.queue, req)

  proc dispatcherBody(ds: ptr DispatchState) {.cps: Actor.} =
    while true:
      suspend()
      let msg = recv()
      assert msg.len >= 1, "dispatcher: empty MailMsg"
      case msg.data[0]
      of MsgKindRequest: ingest(ds, msg)
      of MsgKindTick:    dispatchTick(ds[])
      else: assert false, "dispatcher: unknown msg kind"
      drain(ds)

  proc newDispatcher*(ds: ptr DispatchState): Actor =
    ## Whelp the dispatcher actor, run it to its first park. Feed it with
    ## deliver(actor, mkRequestMsg(...)) / deliver(actor, mkTickMsg()).
    result = Actor(whelp dispatcherBody(ds))
    resume(result)
    assert result.isSuspended, "dispatcher must park awaiting first message"

  # ── Transport pump (shared by kmod and ELF variants) ───────────────────────

  const PumpMaxPerQuantum* = 64   ## bound inbound work per quantum (fairness)

  proc dispatchPump*(ds: ptr DispatchState; a: Actor): int =
    ## One scheduler quantum: move pending requests from the inbound channel
    ## into the actor, then deliver one tick. Returns requests delivered.
    ## A recv that fills the buffer may have been truncated — dropped, not decoded.
    var msg: MailMsg
    msg.data[0] = MsgKindRequest
    for _ in 0 ..< PumpMaxPerQuantum:
      let n = ds.iface.recv(DispatchChannel, addr msg.data[1], MailMsgMax - 1)
      if n <= 0: break
      if n >= MailMsgMax - 1:
        ds.iface.log("dispatch: dropped oversize request\n")
      else:
        msg.len = uint16(n + 1)
        a.deliver(msg)
        inc result
    a.deliver(mkTickMsg())
