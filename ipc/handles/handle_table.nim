# SPDX-License-Identifier: GPL-2.0
## Per-task handle tables: the authority mechanism (docs/proposals/capabilities.md, M1).
##
## A handle is an entry in the CALLING task's own table: a reference to a kernel object plus a set
## of rights and a badge. Rules (each is tested in tests/test_handles.nim):
##   * unforgeable: a handle value is meaningful only in the table it was issued for; a guessed,
##     stale or foreign value fails (index plus a per-slot generation);
##   * conservation: authority is only passed on or narrowed, never created: `duplicate` and
##     `transferOut` can remove rights, never add them;
##   * movement: `transferOut`/`transferIn` carry a handle between tables (in a message); the sender
##     loses it at once, the object stays alive while a "flight" holds the reference;
##   * ownership: the table holds a reference to each object; the last close destroys it and tells
##     the caller (so the owner of the object's payload can free it); a task's death closes all.
## Static arrays only (no heap, no strings, no exceptions): usable in the kernel and on the host.
## The hot path (`lookup`) is one array index, a generation compare, a kind compare and a rights test.

const
  HsMaxTasks*   = 32            ## same as the process table
  HsMaxHandles* = 256           ## per task (tunable)
  HsMaxObjs*    = 1024          ## kernel objects referenced by handles (tunable)

type
  TaskId* = int

  Rights* = distinct uint32
  Handle* = distinct uint32
    ## (generation shl 16) or (slot + 1). 0 is never a handle.

  ObjKind* = enum
    okNone
    okChannelEnd     ## one end of a message channel (ipc/handles/channel)
    okBuffer         ## an ownership buffer (ipc/buffers)
    okPortClient     ## the single-client binding to a device module
    okWait           ## something a task can block on
    okProcess        ## the right to spawn / wait for / kill

  ObjId* = distinct int32

  HsError* = enum
    heOk, heBadTask, heBadHandle, heWrongType, heNoRight, heWidens,
    heTableFull, heObjsFull, heBadObject

  Flight* = object
    ## A handle in transit (in a message): it holds one reference and has left its sender's table.
    obj*: ObjId
    rights*: Rights
    badge*: uint64

  Destroyed* = object
    ## Reported when a close/drop released the last reference to an object.
    happened*: bool
    kind*: ObjKind
    payload*: int32

  Entry = object
    obj: int32                  ## -1 = free
    rights: Rights
    badge: uint64
    gen: uint16

  KObj = object
    live: bool
    kind: ObjKind
    refs: int32
    payload: int32

  Table = object
    attached: bool
    used: int
    entries: array[HsMaxHandles, Entry]

  HandleSpace* = object
    tasks: array[HsMaxTasks, Table]
    objs: array[HsMaxObjs, KObj]
    liveObjs: int

# ── rights ────────────────────────────────────────────────────────────────────

const
  rtNone*      = Rights(0)
  rtRead*      = Rights(1 shl 0)
  rtWrite*     = Rights(1 shl 1)
  rtMap*       = Rights(1 shl 2)
  rtTransfer*  = Rights(1 shl 3)   ## may be sent in a message
  rtDuplicate* = Rights(1 shl 4)   ## may be duplicated (with the same or fewer rights)
  rtWait*      = Rights(1 shl 5)
  rtSignal*    = Rights(1 shl 6)
  rtBind*      = Rights(1 shl 7)
  rtSpawn*     = Rights(1 shl 8)
  rtAll*       = Rights((1 shl 9) - 1)
  rtChannelDefault* = Rights((1 shl 0) or (1 shl 1) or (1 shl 3) or (1 shl 4) or (1 shl 5))

proc `or`*(a, b: Rights): Rights {.inline.} = Rights(uint32(a) or uint32(b))
proc `and`*(a, b: Rights): Rights {.inline.} = Rights(uint32(a) and uint32(b))
proc `==`*(a, b: Rights): bool {.inline.} = uint32(a) == uint32(b)
proc has*(have, need: Rights): bool {.inline.} = (uint32(have) and uint32(need)) == uint32(need)
proc subsetOf*(a, b: Rights): bool {.inline.} = (uint32(a) and not uint32(b)) == 0
proc `==`*(a, b: Handle): bool {.inline.} = uint32(a) == uint32(b)
proc `==`*(a, b: ObjId): bool {.inline.} = int32(a) == int32(b)

const NoHandle* = Handle(0)

proc handleValue(slot: int; gen: uint16): Handle {.inline.} =
  Handle((uint32(gen) shl 16) or uint32(slot + 1))

proc handleSlot(h: Handle): int {.inline.} = int(uint32(h) and 0xFFFF'u32) - 1
proc handleGen(h: Handle): uint16 {.inline.} = uint16(uint32(h) shr 16)

# ── space and objects ─────────────────────────────────────────────────────────

proc hsInit*(s: var HandleSpace) =
  for t in 0 ..< HsMaxTasks:
    s.tasks[t].attached = false
    s.tasks[t].used = 0
    for i in 0 ..< HsMaxHandles:
      s.tasks[t].entries[i] = Entry(obj: -1, gen: 1)
  for o in 0 ..< HsMaxObjs: s.objs[o] = KObj()
  s.liveObjs = 0

proc hsAttach*(s: var HandleSpace; t: TaskId): HsError =
  if t notin 0 ..< HsMaxTasks: return heBadTask
  s.tasks[t].attached = true
  heOk

proc hsNewObject*(s: var HandleSpace; kind: ObjKind; payload: int32; obj: var ObjId): HsError =
  ## A new object with no references yet. Install a handle (or it is garbage the caller must free).
  if kind == okNone: return heBadObject
  for o in 0 ..< HsMaxObjs:
    if not s.objs[o].live:
      s.objs[o] = KObj(live: true, kind: kind, refs: 0, payload: payload)
      inc s.liveObjs
      obj = ObjId(o)
      return heOk
  heObjsFull

proc objOk(s: HandleSpace; o: ObjId): bool {.inline.} =
  int32(o) >= 0 and int32(o) < HsMaxObjs and s.objs[int32(o)].live

proc hsObjKind*(s: HandleSpace; o: ObjId): ObjKind =
  if objOk(s, o): s.objs[int32(o)].kind else: okNone

proc hsObjPayload*(s: HandleSpace; o: ObjId): int32 =
  if objOk(s, o): s.objs[int32(o)].payload else: -1

proc hsObjRefs*(s: HandleSpace; o: ObjId): int =
  if objOk(s, o): int(s.objs[int32(o)].refs) else: 0

proc hsLiveObjects*(s: HandleSpace): int = s.liveObjs
proc hsHandleCount*(s: HandleSpace; t: TaskId): int =
  if t in 0 ..< HsMaxTasks: s.tasks[t].used else: 0

proc release(s: var HandleSpace; o: ObjId; d: var Destroyed) =
  ## Drop one reference; the last one destroys the object.
  let i = int(int32(o))
  dec s.objs[i].refs
  if s.objs[i].refs <= 0:
    d = Destroyed(happened: true, kind: s.objs[i].kind, payload: s.objs[i].payload)
    s.objs[i] = KObj()
    dec s.liveObjs

proc freeSlot(tab: var Table): int =
  for i in 0 ..< HsMaxHandles:
    if tab.entries[i].obj < 0: return i
  -1

proc installRef(s: var HandleSpace; t: TaskId; o: ObjId; rights: Rights; badge: uint64;
                h: var Handle): HsError =
  ## Put a handle in t's table for an object whose reference the caller already accounts for
  ## (`addRef` for a new reference; a flight's reference moves in as is).
  let slot = freeSlot(s.tasks[t])
  if slot < 0: return heTableFull
  let e = addr s.tasks[t].entries[slot]
  e.obj = int32(o); e.rights = rights; e.badge = badge
  inc s.tasks[t].used
  h = handleValue(slot, e.gen)
  heOk

# ── the operations ────────────────────────────────────────────────────────────

proc hsInstall*(s: var HandleSpace; t: TaskId; o: ObjId; rights: Rights; badge: uint64;
                h: var Handle): HsError =
  ## Give task t a handle to object o (a new reference).
  h = NoHandle
  if t notin 0 ..< HsMaxTasks or not s.tasks[t].attached: return heBadTask
  if not objOk(s, o): return heBadObject
  result = installRef(s, t, o, rights, badge, h)
  if result == heOk: inc s.objs[int32(o)].refs

proc hsLookup*(s: HandleSpace; t: TaskId; h: Handle; kind: ObjKind; need: Rights;
               obj: var ObjId; badge: var uint64): HsError {.inline.} =
  ## THE hot path. Succeeds only if h is a live handle in t's own table, of the right kind, with
  ## at least the needed rights.
  if t notin 0 ..< HsMaxTasks: return heBadTask
  let slot = handleSlot(h)
  if slot < 0 or slot >= HsMaxHandles: return heBadHandle
  let e = unsafeAddr s.tasks[t].entries[slot]
  if e.obj < 0 or e.gen != handleGen(h): return heBadHandle
  if s.objs[e.obj].kind != kind: return heWrongType
  if not e.rights.has(need): return heNoRight
  obj = ObjId(e.obj); badge = e.badge
  heOk

proc hsLookupAny*(s: HandleSpace; t: TaskId; h: Handle; need: Rights; kind: var ObjKind;
                  obj: var ObjId; rights: var Rights; badge: var uint64): HsError =
  ## Like hsLookup for a caller that does not know the kind yet (e.g. the handles listed to be sent
  ## in a message). Same rules: the handle must be live in t's own table and carry `need`.
  if t notin 0 ..< HsMaxTasks: return heBadTask
  let slot = handleSlot(h)
  if slot < 0 or slot >= HsMaxHandles: return heBadHandle
  let e = s.tasks[t].entries[slot]
  if e.obj < 0 or e.gen != handleGen(h): return heBadHandle
  if not e.rights.has(need): return heNoRight
  kind = s.objs[e.obj].kind; obj = ObjId(e.obj); rights = e.rights; badge = e.badge
  heOk

proc hsDiscardObject*(s: var HandleSpace; o: ObjId) =
  ## Destroy an object that never received a handle (a creation that failed half way).
  if objOk(s, o) and s.objs[int32(o)].refs == 0:
    s.objs[int32(o)] = KObj()
    dec s.liveObjs

proc hsRights*(s: HandleSpace; t: TaskId; h: Handle; rights: var Rights): HsError =
  ## Any live handle's rights, whatever its kind (for tests and diagnostics).
  if t notin 0 ..< HsMaxTasks: return heBadTask
  let slot = handleSlot(h)
  if slot < 0 or slot >= HsMaxHandles: return heBadHandle
  let e = s.tasks[t].entries[slot]
  if e.obj < 0 or e.gen != handleGen(h): return heBadHandle
  rights = e.rights
  heOk

proc hsDuplicate*(s: var HandleSpace; t: TaskId; h: Handle; newRights: Rights;
                  h2: var Handle): HsError =
  ## A second handle to the same object, in the same table, with the same badge and rights that are
  ## a subset of the original's. Needs rtDuplicate.
  h2 = NoHandle
  var o: ObjId
  var badge: uint64
  let slot = handleSlot(h)
  if t notin 0 ..< HsMaxTasks: return heBadTask
  if slot < 0 or slot >= HsMaxHandles: return heBadHandle
  let e = s.tasks[t].entries[slot]
  if e.obj < 0 or e.gen != handleGen(h): return heBadHandle
  if not e.rights.has(rtDuplicate): return heNoRight
  if not newRights.subsetOf(e.rights): return heWidens
  o = ObjId(e.obj); badge = e.badge
  result = installRef(s, t, o, newRights, badge, h2)
  if result == heOk: inc s.objs[int32(o)].refs

proc closeSlot(s: var HandleSpace; t: TaskId; slot: int; d: var Destroyed) =
  let o = ObjId(s.tasks[t].entries[slot].obj)
  s.tasks[t].entries[slot].obj = -1
  s.tasks[t].entries[slot].rights = rtNone
  s.tasks[t].entries[slot].badge = 0
  s.tasks[t].entries[slot].gen = s.tasks[t].entries[slot].gen + 1
  if s.tasks[t].entries[slot].gen == 0: s.tasks[t].entries[slot].gen = 1
  dec s.tasks[t].used
  release(s, o, d)

proc hsClose*(s: var HandleSpace; t: TaskId; h: Handle; d: var Destroyed): HsError =
  d = Destroyed()
  if t notin 0 ..< HsMaxTasks: return heBadTask
  let slot = handleSlot(h)
  if slot < 0 or slot >= HsMaxHandles: return heBadHandle
  let e = s.tasks[t].entries[slot]
  if e.obj < 0 or e.gen != handleGen(h): return heBadHandle
  closeSlot(s, t, slot, d)
  heOk

proc hsTransferOut*(s: var HandleSpace; t: TaskId; h: Handle; narrow: Rights;
                    f: var Flight): HsError =
  ## Take the handle out of t's table for a message. Needs rtTransfer; `narrow` (a subset of the
  ## handle's rights) is what the receiver will get. The sender no longer has the handle.
  f = Flight()
  if t notin 0 ..< HsMaxTasks: return heBadTask
  let slot = handleSlot(h)
  if slot < 0 or slot >= HsMaxHandles: return heBadHandle
  let e = s.tasks[t].entries[slot]
  if e.obj < 0 or e.gen != handleGen(h): return heBadHandle
  if not e.rights.has(rtTransfer): return heNoRight
  if not narrow.subsetOf(e.rights): return heWidens
  f = Flight(obj: ObjId(e.obj), rights: narrow, badge: e.badge)
  # the reference moves into the flight: free the slot without releasing
  s.tasks[t].entries[slot].obj = -1
  s.tasks[t].entries[slot].rights = rtNone
  s.tasks[t].entries[slot].badge = 0
  s.tasks[t].entries[slot].gen = s.tasks[t].entries[slot].gen + 1
  if s.tasks[t].entries[slot].gen == 0: s.tasks[t].entries[slot].gen = 1
  dec s.tasks[t].used
  heOk

proc hsTransferIn*(s: var HandleSpace; t: TaskId; f: Flight; h: var Handle): HsError =
  ## Deliver a flight into t's table. On failure (table full) the flight is still valid: the caller
  ## keeps it queued or drops it with hsDropFlight.
  h = NoHandle
  if t notin 0 ..< HsMaxTasks or not s.tasks[t].attached: return heBadTask
  installRef(s, t, f.obj, f.rights, f.badge, h)

proc hsDropFlight*(s: var HandleSpace; f: Flight; d: var Destroyed) =
  ## A message was discarded: release the reference the flight holds.
  d = Destroyed()
  if objOk(s, f.obj): release(s, f.obj, d)

proc hsFreeSlots*(s: HandleSpace; t: TaskId): int =
  if t in 0 ..< HsMaxTasks: HsMaxHandles - s.tasks[t].used else: 0

type DestroyCb* = proc(kind: ObjKind; payload: int32) {.nimcall.}

proc hsCloseAll*(s: var HandleSpace; t: TaskId; cb: DestroyCb = nil) =
  ## The task died: close every handle it holds. Every object that loses its last reference is
  ## reported through `cb`. (Objects whose destruction releases further handles are the caller's
  ## concern: see channel.nim, which loops until nothing is left.)
  if t notin 0 ..< HsMaxTasks: return
  for slot in 0 ..< HsMaxHandles:
    if s.tasks[t].entries[slot].obj >= 0:
      var d: Destroyed
      closeSlot(s, t, slot, d)
      if d.happened and cb != nil: cb(d.kind, d.payload)
  s.tasks[t].attached = false
