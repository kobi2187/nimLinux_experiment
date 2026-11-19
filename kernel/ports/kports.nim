# SPDX-License-Identifier: GPL-2.0
## Kernel glue for device ports (K3 layer 2): the input port's device module, its exclusive binding in the
## kernel's handle space, the two syscalls a program uses (PortCall, PortEvent), waiting on a port, and the
## release of the port when its holder dies.
##
## The input device module lives in the kernel today (the virtio-input driver feeds it), so its transport
## is the DIRECT one: a program's request is a procedure call into `inputHandler`, events are pushed into
## the client's ring by the driver's IRQ handler. When the module moves to a server, only the transport
## changes (ipc/ports/link.nim); the program's code does not.
##
## Who holds the port: exactly one task, by an `okPortClient` handle that cannot be duplicated. At boot the
## shell holds it (the console reads keys). The launcher MOVES it to a program whose manifest grants
## `input`; when that program exits the handle dies, the port is free, and the shell takes it back. A
## program that was not given the handle can neither read keys nor bind the port.
##
## Errors (negative returns): -1 bad handle or argument (the gate's generic refusal); -(40 + ord(PortStatus))
## for port statuses (-41 pending ... see ipc/ports/port.nim).
import ../../ipc/ports/port
import ../../ipc/ports/link
import ../../ipc/ports/input_port
import ../../ipc/handles/handle_table
import ../../ipc/handles/channel
import ../../input/evdev_decode
import ../handles/khandles
import ../process_table
import ../../arch/x86_64/cpu_primitives
import ../../core/log

const
  StatusBase = 40

func waitKey(kind: PortKind): int32 = int32(-1 - ord(kind))   ## what a task waiting on a port is woken by (never an end index)

var
  gReg: PortRegistry
  gDecoder: EvdevDecoder
  gLinks: array[PortKind, Link]                   ## each port's direct link (client side + event ring)
  gModules: array[PortKind, DeviceModule]         ## who answers each port's requests
  gInputEmit: Emitter                             ## the input module's side of its link
  gReleased: array[PortKind, proc() {.nimcall.}]  ## told when a port's holder lets go (installed by the device module)

proc inputHandler(ctx: pointer; req: PortMsg; rep: var PortMsg) {.nimcall.} =
  var op: InputOp
  let s = opOf(req, op)
  if s != psOk: rep.status = s; return
  case op                                         # exhaustive: a new InputOp will not compile until handled
  of ioInfo: putPayload(rep, InputInfo(keyboards: 1, pointers: 1, queueSize: uint16(EventRingSize)))
  of ioFlush: discard                             # the module buffers nothing of its own

proc refusingHandler(ctx: pointer; req: PortMsg; rep: var PortMsg) {.nimcall.} =
  rep.status = psNoDevice                         # a port whose module has not been installed refuses visibly

proc resetLink(kind: PortKind) =
  gLinks[kind] = directLink(gModules[kind])
  case kind
  of pkInput: gInputEmit = directEmitter(addr gLinks[pkInput])
  of pkDisplay: discard

proc kportInstallModule*(kind: PortKind; handler: Handler; onReleased: proc() {.nimcall.} = nil) =
  ## The owner of a device module installs it (hook inversion: this module does not import the device).
  ## `onReleased` runs when the port's holder lets go (exit or close), so the device can take back what
  ## the holder had (the display hands the screen back to the console).
  gModules[kind] = DeviceModule(handler: handler, ctx: nil)
  gReleased[kind] = onReleased
  resetLink(kind)

proc kportOnDestroyed(kind: ObjKind; payload: int32) {.nimcall.} =
  ## The last reference to a port object died (the holder exited or closed it): the port is free, and the
  ## next holder starts with an empty queue (nothing the last one did not read reaches it).
  portOnDestroyed(gReg, kind, payload)
  if kind == okPortClient and payload >= 0 and payload <= int32(ord(high(PortKind))):
    let k = PortKind(payload)
    resetLink(k)
    if gReleased[k] != nil: gReleased[k]()

proc portProbe(t: int; h: Handle; key: var int32; bits: var uint32): bool {.nimcall.} =
  var o: ObjId
  var b: uint64
  if hsLookup(gHs, t, h, okPortClient, rtWait, o, b) != heOk: return false
  let payload = hsObjPayload(gHs, o)
  if payload < 0 or payload > int32(ord(high(PortKind))): return false
  let kind = PortKind(payload)
  key = waitKey(kind)
  bits = if eventsQueued(gLinks[kind]) > 0: 1'u32 else: 0'u32
  true

proc kportInit*() =
  gReg = PortRegistry()
  gDecoder = EvdevDecoder()
  for k in PortKind: gModules[k] = DeviceModule(handler: refusingHandler, ctx: nil)
  kportInstallModule(pkInput, inputHandler)
  kportInstallModule(pkDisplay, refusingHandler)    # replaced by kernel/display's module at its init
  chSetDestroyHook(kportOnDestroyed)
  gPortProbe = portProbe

# ── binding ───────────────────────────────────────────────────────────────────

proc kportBind*(kind: PortKind; task: int): Handle =
  ## Make `task` the holder of the port. NoHandle if the port is held.
  var h: Handle
  if portBind(gHs, gReg, kind, task, h) != psOk: return NoHandle
  h

proc kportHeld*(kind: PortKind): bool = portHeld(gReg, kind)

proc kportHolds*(kind: PortKind; task: int; h: Handle): bool =
  ## Does `task` still hold the port `kind` through handle h? (The shell asks before using it.)
  h != NoHandle and portUse(gHs, task, h, kind, rtRead) == psOk

# The kernel's own client: the shell's console holds each port unless it has been moved to a program, and
# takes it back when the program is gone. (The console is not special in kind: it holds ordinary handles.)
var
  gConsoleTask = -1
  gConsoleH: array[PortKind, Handle]

proc kportConsoleEnsure*(task: int) =
  ## Called by the console in its own task: hold every port nobody holds.
  gConsoleTask = task
  for k in PortKind:
    if not kportHolds(k, task, gConsoleH[k]) and not portHeld(gReg, k): gConsoleH[k] = kportBind(k, task)

proc kportConsoleHandle*(kind: PortKind): Handle = gConsoleH[kind]   ## what the launcher moves to a program granted it

proc kportConsoleHolds*(kind: PortKind; task: int): bool = kportHolds(kind, task, gConsoleH[kind])

# ── the device module's feed (IRQ context) ────────────────────────────────────

proc kportFeedEvdev*(typ, code: uint16; value: int32) =
  ## The virtio-input driver hands over one evdev event. Called from the IRQ handler: static arrays only.
  var outEv: array[MaxOut, InputEvent]
  let n = gDecoder.feed(typ, code, value, outEv)
  if n == 0 or not portHeld(gReg, pkInput): return
  for i in 0 ..< n:
    var m: PortMsg
    encode(outEv[i], m)
    emit(gInputEmit, gHs, gCh, m)
  khWakeKey(waitKey(pkInput))

proc kportInject*(typ, code: uint16; value: int32) =
  ## Feed one evdev event as the driver would, from task context (the shell's `keytest`): the same decoder,
  ## the same port. Interrupts are off so the IRQ handler cannot interleave with it.
  let fl = disableInterrupts()
  kportFeedEvdev(typ, code, value)
  restoreInterrupts(fl)

proc kportConsoleNextEvent*(task: int; ev: var InputEvent): bool =
  ## The console's next event, only while the console really holds the port. Interrupts are off while the
  ## ring is touched (the driver fills it from the IRQ handler).
  if not kportConsoleHolds(pkInput, task): return false
  let fl = disableInterrupts()
  var m: PortMsg
  let got = nextEvent(gLinks[pkInput], gHs, gCh, m)
  restoreInterrupts(fl)
  if not got: return false
  decode(m, ev) == psOk

# ── syscalls ──────────────────────────────────────────────────────────────────

template statusCode(s: PortStatus): int = -(StatusBase + ord(s))

proc heldKind(t: int; h: uint32; need: Rights; kind: var PortKind): bool =
  var o: ObjId
  var b: uint64
  if hsLookup(gHs, t, Handle(h), okPortClient, need, o, b) != heOk: return false
  let payload = hsObjPayload(gHs, o)
  if payload < 0 or payload > int32(ord(high(PortKind))): return false
  kind = PortKind(payload)
  true

proc abiPortCall*(h: uint32; buf: pointer; len: int; cap: int): int {.nimcall.} =
  ## Send one request (wire form, `len` bytes) through port handle h; the reply (wire form) is written
  ## back to `buf` and its length returned. `cap` must be at least a whole message (256).
  let t = khMe()
  if t < 0 or len < PortHeaderBytes or len > cap or cap < ChMsgBytes: return -1
  var kind: PortKind
  if not heldKind(t, h, rtWrite, kind): return -1
  let bytes = cast[ptr UncheckedArray[byte]](buf)
  var req: PortMsg
  let ps = fromWire(bytes.toOpenArray(0, len - 1), req)
  if ps != psOk: return statusCode(ps)
  var rep = PortMsg(cls: mcReply, status: psOk, op: req.op, seq: req.seq)
  if req.cls == mcRequest and req.op == PortDescribeOp:
    putPayload(rep, uint8(ord(kind)))              # answered here, for every port alike
  else:
    case kind
    of pkInput, pkDisplay:                          # both are direct links today; the device module answers
      var q = req
      let fl = disableInterrupts()
      var s = submit(gLinks[kind], gHs, gCh, q)
      if s == psOk: s = takeReply(gLinks[kind], gHs, gCh, rep)
      restoreInterrupts(fl)
      if s != psOk: return statusCode(s)
  var wire: array[ChMsgBytes, byte]
  let n = toWire(rep, wire)
  for i in 0 ..< n: bytes[i] = wire[i]
  n

proc abiPortEvent*(h: uint32; buf: pointer; cap: int): int {.nimcall.} =
  ## The next event of port handle h, in wire form, written to `buf` (cap >= 256). Returns its length,
  ## 0 if none is waiting, negative on a bad handle.
  let t = khMe()
  if t < 0 or cap < ChMsgBytes: return -1
  var kind: PortKind
  if not heldKind(t, h, rtRead, kind): return -1
  var m: PortMsg
  var got = false
  case kind
  of pkInput, pkDisplay:                            # the display has no events: its ring stays empty
    let fl = disableInterrupts()
    got = nextEvent(gLinks[kind], gHs, gCh, m)
    restoreInterrupts(fl)
  if not got: return 0
  var wire: array[ChMsgBytes, byte]
  let n = toWire(m, wire)
  let bytes = cast[ptr UncheckedArray[byte]](buf)
  for i in 0 ..< n: bytes[i] = wire[i]
  n
