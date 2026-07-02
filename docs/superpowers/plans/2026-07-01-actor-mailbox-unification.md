# Actor/Mailbox Unification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Unify NimixOS's three ad-hoc queue shapes (ServerChan ring, dispatcher priority heap, virtqueues) and every server onto one actor/mailbox primitive backed by CPS coroutines, so a server is an actor that blocks on `receive()` and resumes on message — no locks, no polling, scaling to large actor counts.

**Architecture:** A `Mailbox` is the existing `ServerChan` MPSC ring generalized into a reusable primitive. An `Actor` is a CPS `Continuation` that owns one mailbox and a `receive()` cpsMagic suspend-point: empty mailbox → suspend (return nil to trampoline); message posted → actor re-trampolined by the actor scheduler. Servers become actors. The dispatcher's priority queue stays as a *policy layer* that feeds a mailbox — priority is a scheduling concern layered on top of the uniform mailbox, not a competing queue type. Virtqueues stay hardware-specific but expose a mailbox-shaped `receive` for used-ring completions so driver code reads uniformly.

**Tech Stack:** Nim, nim-cps (`whelp`/`trampoline`/`cpsMagic`), `--mm:arc --panics:on` for actor code, `--os:any` kernel context, existing `msgpack_chan` for payloads.

## Global Constraints

- CPS code MUST compile under `--mm:arc --panics:on`. It is NOT compatible with `--mm:refc`. The default host-test flag is `--mm:refc` — pure-logic modules stay refc-testable; actor-runtime modules get their own `--mm:arc` test invocation (pattern: `tests/test_cps_eval.nim`, Makefile line ~282).
- Kernel modules (`--os:any`) MUST NOT import stdlib that pulls `osalloc` (no `std/options`, no `std/tables`). Use the existing custom `MaybeMsg`-style option and fixed-size arrays. Follow `ipc/server_chan.nim` conventions.
- Files > ~100 lines split into focused modules (project code-size rule). Procs 5–8 lines where practical (complexity rule).
- Assert invariants at entry/state-transitions/ring-bounds (assert-liberally rule).
- No new external dependencies; nim-cps is already vendored and proven (`test_cps_eval.nim`).
- Every `make build` (3 models: microkernel/sasos/monolithic) and `make test` MUST stay green at each task's commit.
- Preserve existing public APIs during migration (`serverChanPost`/`serverChanRecv`, `virtioSndPlay`, etc.) until their callers are migrated — deprecate, don't break.
- The single-threaded no-locks axiom holds: mailbox is lock-free for single-CPU; SMP spinlock is a documented future note, not built now.

---

## File Structure

- `ipc/mailbox.nim` (NEW) — the `Mailbox[N]` generic MPSC ring primitive extracted/generalized from ServerChan. One responsibility: bounded message queue with post/tryRecv. No CPS, no registry — pure data structure, refc-testable.
- `ipc/mailbox_registry.nim` (NEW) — named-mailbox registry (find by name), extracted from ServerChan's registry half. `--os:any`.
- `runtime/actor.nim` (NEW) — the CPS actor: `Actor` continuation type, `receive()` cpsMagic suspend-point, `spawnActor`, and the `actorPost` wake path. Compiled `--mm:arc`. One responsibility: bind a mailbox to a CPS continuation with block-on-receive.
- `runtime/actor_scheduler.nim` (NEW) — the ready-list of runnable actors + `runActors()` trampoline pump. `--mm:arc`. One responsibility: drive suspended actors when their mailboxes get messages.
- `ipc/server_chan.nim` (MODIFY) — reimplement `ServerChan` as a thin compat shim over `Mailbox` + `mailbox_registry` so existing callers keep working. Shrinks.
- `servers/dispatch/dispatch_logic.nim` (MODIFY) — dispatcher becomes an actor: its ingest loop is `receive()`-driven; priority queue stays as the ordering policy applied to drained messages.
- `servers/media/audio_server_elf.nim` (MODIFY) — audio_server becomes the reference actor (receive loop instead of hand-rolled `nimixChanRecv` poll).
- `drivers/virtio/virtqueue.nim` (MODIFY) — add `vqReceive` mailbox-shaped completion reader (thin wrapper over `virtqueuePop`) so driver completion code reads uniformly. No behavior change.
- `tests/test_mailbox.nim` (NEW) — refc host test for `Mailbox` ring semantics.
- `tests/test_actor.nim` (NEW) — arc host test for actor receive/suspend/wake.
- `DECISIONS.md` (MODIFY) — record the actor/mailbox model decision + priority-as-policy layering.

---

### Task 1: Extract the `Mailbox` primitive

**Files:**
- Create: `ipc/mailbox.nim`
- Test: `tests/test_mailbox.nim`
- Modify: `Makefile` (add `test_mailbox.nim` to the refc test list near the other `$(NIM) c -r $(TEST_FLAGS) tests/test_*.nim` lines)

**Interfaces:**
- Consumes: nothing (leaf primitive).
- Produces:
  - `type Mailbox*[N: static int] = object` with fields `buf: array[N, MailMsg]`, `head, tail, count: int`.
  - `type MailMsg* = object` with `len*: uint16` and `data*: array[MailMsgMax, byte]`, `MailMsgMax* = 256`.
  - `type MaybeMail* = object` with `hasValue*: bool` and `value*: MailMsg`.
  - `proc mbInit*[N](mb: var Mailbox[N])`
  - `proc mbPost*[N](mb: var Mailbox[N]; msg: MailMsg): bool` — false when full.
  - `proc mbTryRecv*[N](mb: var Mailbox[N]): MaybeMail` — hasValue=false when empty.
  - `proc mbCount*[N](mb: Mailbox[N]): int`
  - `proc mbIsEmpty*[N](mb: Mailbox[N]): bool`

- [ ] **Step 1: Write the failing test**

```nim
# tests/test_mailbox.nim
# SPDX-License-Identifier: GPL-2.0
## Host test for the Mailbox MPSC ring primitive.
import ipc/mailbox
import unittest

proc mkMsg(b: byte): MailMsg =
  result.len = 1
  result.data[0] = b

suite "Mailbox ring":
  test "post then recv is FIFO":
    var mb: Mailbox[4]
    mbInit(mb)
    check mbPost(mb, mkMsg(1))
    check mbPost(mb, mkMsg(2))
    check mbCount(mb) == 2
    let a = mbTryRecv(mb)
    check a.hasValue and a.value.data[0] == 1
    let b = mbTryRecv(mb)
    check b.hasValue and b.value.data[0] == 2
    check mbIsEmpty(mb)

  test "recv on empty returns hasValue=false":
    var mb: Mailbox[2]
    mbInit(mb)
    check not mbTryRecv(mb).hasValue

  test "post on full returns false, no overwrite":
    var mb: Mailbox[2]
    mbInit(mb)
    check mbPost(mb, mkMsg(10))
    check mbPost(mb, mkMsg(20))
    check not mbPost(mb, mkMsg(30))     # full
    check mbTryRecv(mb).value.data[0] == 10   # oldest intact

  test "wraparound preserves order":
    var mb: Mailbox[2]
    mbInit(mb)
    discard mbPost(mb, mkMsg(1))
    discard mbTryRecv(mb)               # head advances past 0
    discard mbPost(mb, mkMsg(2))
    discard mbPost(mb, mkMsg(3))        # tail wraps
    check mbTryRecv(mb).value.data[0] == 2
    check mbTryRecv(mb).value.data[0] == 3

echo "=== All mailbox tests passed ==="
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/kl/apps/Nim/bin/nim c -r --skipParentCfg --mm:refc --os:linux --path:. tests/test_mailbox.nim`
Expected: FAIL — `cannot open file: ipc/mailbox`.

- [ ] **Step 3: Write minimal implementation**

```nim
# ipc/mailbox.nim
# SPDX-License-Identifier: GPL-2.0
## Mailbox — bounded MPSC ring of fixed-size messages.
##
## The one queue primitive for NimixOS actors. Lock-free for single-CPU use
## (SMP will guard head/tail with a spinlock — deferred). Kernel-safe: no
## stdlib, no heap; --os:any compatible. Payload bytes are copied in/out.

const MailMsgMax* = 256   ## max payload bytes per message

type
  MailMsg* = object
    len*:  uint16
    data*: array[MailMsgMax, byte]

  MaybeMail* = object
    hasValue*: bool
    value*:    MailMsg

  Mailbox*[N: static int] = object
    buf:   array[N, MailMsg]
    head:  int
    tail:  int
    count: int

proc mbInit*[N](mb: var Mailbox[N]) =
  mb.head = 0; mb.tail = 0; mb.count = 0

proc mbCount*[N](mb: Mailbox[N]): int = mb.count
proc mbIsEmpty*[N](mb: Mailbox[N]): bool = mb.count == 0

proc mbPost*[N](mb: var Mailbox[N]; msg: MailMsg): bool =
  ## Enqueue. False when full (caller applies backpressure).
  if mb.count >= N: return false
  mb.buf[mb.tail] = msg
  mb.tail = (mb.tail + 1) mod N
  inc mb.count
  assert mb.count <= N, "mailbox count exceeded capacity"
  true

proc mbTryRecv*[N](mb: var Mailbox[N]): MaybeMail =
  ## Dequeue oldest. hasValue=false when empty.
  if mb.count == 0:
    result.hasValue = false
    return
  result.value    = mb.buf[mb.head]
  result.hasValue = true
  mb.head = (mb.head + 1) mod N
  dec mb.count
  assert mb.count >= 0, "mailbox count underflow"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `/home/kl/apps/Nim/bin/nim c -r --skipParentCfg --mm:refc --os:linux --path:. tests/test_mailbox.nim`
Expected: PASS — all 4 cases + `=== All mailbox tests passed ===`.

- [ ] **Step 5: Add to Makefile test list**

Add this line adjacent to the other refc test invocations (after `tests/test_pci.nim` grouping):

```makefile
	$(NIM) c -r $(TEST_FLAGS) tests/test_mailbox.nim
```

- [ ] **Step 6: Verify make test still green**

Run: `make test 2>&1 | grep -iE "error|fail|passed" | grep -v Warning | tail`
Expected: `=== All tests passed ===`, mailbox line present.

- [ ] **Step 7: Commit**

```bash
git add ipc/mailbox.nim tests/test_mailbox.nim Makefile
git commit -m "ipc: extract Mailbox MPSC ring primitive"
```

---

### Task 2: Named mailbox registry

**Files:**
- Create: `ipc/mailbox_registry.nim`
- Test: extend `tests/test_mailbox.nim` (registry suite)

**Interfaces:**
- Consumes: `Mailbox`, `MailMsg` from Task 1. Registry stores `pointer` + name (generic `Mailbox[N]` can't be a heterogeneous array member, so the registry holds an untyped `pointer` to the mailbox plus a `postFn`/`recvFn` thunk pair — same nimcall-vtable pattern used across this codebase).
- Produces:
  - `type MailboxRef* = object` with `name*: array[64, char]`, `mb*: pointer`, `post*: proc(mb: pointer; msg: MailMsg): bool {.nimcall.}`, `tryRecv*: proc(mb: pointer): MaybeMail {.nimcall.}`.
  - `proc mbRegistryInit*()`
  - `proc mbRegister*(name: string; mb: pointer; post: ...; tryRecv: ...)`
  - `proc mbFind*(name: string): ptr MailboxRef` — nil if absent.
  - `proc mbPostByName*(name: string; msg: MailMsg): bool` — routes via the found ref's `post` thunk; false if not found or full.

- [ ] **Step 1: Write the failing test** — append to `tests/test_mailbox.nim`:

```nim
import ipc/mailbox_registry

# Concrete thunks binding a Mailbox[4] into the untyped registry.
proc post4(mb: pointer; msg: MailMsg): bool {.nimcall.} =
  mbPost(cast[ptr Mailbox[4]](mb)[], msg)
proc recv4(mb: pointer): MaybeMail {.nimcall.} =
  mbTryRecv(cast[ptr Mailbox[4]](mb)[])

suite "Mailbox registry":
  test "register, find, post-by-name":
    mbRegistryInit()
    var inbox: Mailbox[4]
    mbInit(inbox)
    mbRegister("audio", addr inbox, post4, recv4)
    check mbFind("audio") != nil
    check mbFind("missing") == nil
    check mbPostByName("audio", mkMsg(7))
    check mbTryRecv(inbox).value.data[0] == 7

  test "post to unknown name returns false":
    mbRegistryInit()
    check not mbPostByName("nope", mkMsg(1))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/kl/apps/Nim/bin/nim c -r --skipParentCfg --mm:refc --os:linux --path:. tests/test_mailbox.nim`
Expected: FAIL — `cannot open file: ipc/mailbox_registry`.

- [ ] **Step 3: Write minimal implementation**

```nim
# ipc/mailbox_registry.nim
# SPDX-License-Identifier: GPL-2.0
## Named mailbox registry — resolve a mailbox by name and post to it.
##
## Mailbox[N] is generic, so the registry stores an untyped pointer plus a
## nimcall post/tryRecv thunk pair (the vtable pattern used throughout the
## kernel). --os:any: fixed-size arrays, no stdlib containers.
import mailbox

const
  MbNameLen*    = 64
  MaxMailboxes* = 32

type
  PostThunk*    = proc(mb: pointer; msg: MailMsg): bool {.nimcall.}
  RecvThunk*    = proc(mb: pointer): MaybeMail {.nimcall.}
  MailboxRef* = object
    name*:    array[MbNameLen, char]
    mb*:      pointer
    post*:    PostThunk
    tryRecv*: RecvThunk

var registry: array[MaxMailboxes, MailboxRef]
var count: int = 0

proc mbRegistryInit*() =
  count = 0
  for i in 0..<MaxMailboxes: registry[i].mb = nil

proc fillName(dst: var array[MbNameLen, char]; src: string) =
  let lim = if src.len < MbNameLen - 1: src.len else: MbNameLen - 1
  for i in 0..<lim: dst[i] = src[i]
  dst[lim] = '\0'

proc nameEq(n: array[MbNameLen, char]; src: string): bool =
  var i = 0
  while i < MbNameLen and n[i] != '\0':
    if i >= src.len or n[i] != src[i]: return false
    inc i
  i == src.len

proc mbRegister*(name: string; mb: pointer; post: PostThunk; tryRecv: RecvThunk) =
  assert mb != nil, "mbRegister: nil mailbox"
  if count >= MaxMailboxes: return
  fillName(registry[count].name, name)
  registry[count].mb      = mb
  registry[count].post    = post
  registry[count].tryRecv = tryRecv
  inc count

proc mbFind*(name: string): ptr MailboxRef =
  for i in 0..<count:
    if registry[i].mb != nil and nameEq(registry[i].name, name):
      return addr registry[i]
  nil

proc mbPostByName*(name: string; msg: MailMsg): bool =
  let r = mbFind(name)
  if r == nil: return false
  r.post(r.mb, msg)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `/home/kl/apps/Nim/bin/nim c -r --skipParentCfg --mm:refc --os:linux --path:. tests/test_mailbox.nim`
Expected: PASS — registry suite green.

- [ ] **Step 5: Commit**

```bash
git add ipc/mailbox_registry.nim tests/test_mailbox.nim
git commit -m "ipc: named mailbox registry with nimcall thunks"
```

---

### Task 3: CPS actor with block-on-receive

**Files:**
- Create: `runtime/actor.nim`
- Test: `tests/test_actor.nim` (arc-compiled)
- Modify: `Makefile` (add an arc test invocation mirroring the `test_cps_eval.nim` line at ~282)

**Interfaces:**
- Consumes: `Mailbox`, `MailMsg`, `MaybeMail` (Task 1); `cps` primitives (`Continuation`, `whelp`, `trampoline`, `cpsMagic`).
- Produces:
  - `type Actor* = ref object of Continuation` with field `inbox*: ptr Mailbox[ActorInboxDepth]` and `pending*: MailMsg` (slot the resumed body reads).
  - `const ActorInboxDepth* = 16`
  - `proc receive*(a: Actor): Actor {.cpsMagic.}` — if inbox empty, suspend (return nil); else pop into `a.pending` and continue (return a). NOTE: cpsMagic receiving the continuation is the proven pattern from `test_cps_eval.nim::suspend`.
  - `proc actorReady*(a: Actor): bool` — inbox non-empty (scheduler uses this to decide re-trampoline).

- [ ] **Step 1: Write the failing test**

```nim
# tests/test_actor.nim
# SPDX-License-Identifier: GPL-2.0
## Actor receive/suspend/wake test. MUST compile --mm:arc --panics:on.
import ipc/mailbox
import runtime/actor
import cps

var log: seq[int]

proc mkMsg(b: byte): MailMsg =
  result.len = 1; result.data[0] = b

# An actor body that receives two messages, logging each payload byte.
proc worker(a: Actor) {.cps: Actor.} =
  receive(a)                       # suspends until msg 1
  log.add(int(a.pending.data[0]))
  receive(a)                       # suspends until msg 2
  log.add(int(a.pending.data[0]))

proc testActorReceiveSuspendWake() =
  var inbox: Mailbox[ActorInboxDepth]
  mbInit(inbox)
  var a = Actor(inbox: addr inbox)
  var c = whelp worker(a)
  c = trampoline(c)                # runs to first receive → suspends (empty)
  assert log.len == 0, "actor should block on empty inbox"
  discard mbPost(inbox, mkMsg(42))
  c = trampoline(c)                # message present → resumes, logs 42, blocks again
  assert log == @[42], "actor should process first message"
  discard mbPost(inbox, mkMsg(99))
  c = trampoline(c)                # resumes, logs 99, completes
  assert log == @[42, 99], "actor should process second message"
  echo "PASS: actor receive/suspend/wake"

testActorReceiveSuspendWake()
echo "All actor tests passed."
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/kl/apps/Nim/bin/nim c -r --skipParentCfg --mm:arc --panics:on --path:. -d:noSignalHandler tests/test_actor.nim`
Expected: FAIL — `cannot open file: runtime/actor`.

- [ ] **Step 3: Write minimal implementation**

```nim
# runtime/actor.nim
# SPDX-License-Identifier: GPL-2.0
## Actor — a CPS continuation bound to one mailbox, blocking on receive.
##
## receive() is a cpsMagic suspend-point (same mechanism as test_cps_eval's
## suspend): empty inbox returns nil to the trampoline (park the actor);
## a posted message pops into `pending` and the body resumes. No locks — the
## actor scheduler re-trampolines a parked actor when its inbox fills.
##
## MUST compile --mm:arc --panics:on (nim-cps requirement).
import cps
import ../ipc/mailbox

const ActorInboxDepth* = 16

type
  Actor* = ref object of Continuation
    inbox*:   ptr Mailbox[ActorInboxDepth]
    pending*: MailMsg

proc actorReady*(a: Actor): bool =
  ## True when the inbox has a message waiting (scheduler re-runs the actor).
  a.inbox != nil and not mbIsEmpty(a.inbox[])

proc receive*(a: Actor): Actor {.cpsMagic.} =
  ## Suspend until a message is available; on resume, `a.pending` holds it.
  assert a.inbox != nil, "receive: actor has no inbox"
  let m = mbTryRecv(a.inbox[])
  if not m.hasValue:
    return nil            # park: trampoline stops, scheduler re-runs when ready
  a.pending = m.value
  a                       # continue immediately
```

- [ ] **Step 4: Run test to verify it passes**

Run: `/home/kl/apps/Nim/bin/nim c -r --skipParentCfg --mm:arc --panics:on --path:. -d:noSignalHandler tests/test_actor.nim`
Expected: PASS — `PASS: actor receive/suspend/wake` + `All actor tests passed.`

- [ ] **Step 5: Add arc test to Makefile**

Add adjacent to the `test_cps_eval.nim` line (~282):

```makefile
	$(NIM) c -r --skipParentCfg --mm:arc --panics:on --path:$(CURDIR) -d:noSignalHandler tests/test_actor.nim
```

- [ ] **Step 6: Verify make test green**

Run: `make test 2>&1 | grep -iE "error|fail|passed|actor" | grep -v Warning | tail`
Expected: actor test passes; `=== All tests passed ===`.

- [ ] **Step 7: Commit**

```bash
git add runtime/actor.nim tests/test_actor.nim Makefile
git commit -m "runtime: CPS actor with block-on-receive mailbox"
```

---

### Task 4: Actor scheduler (ready-list trampoline pump)

**Files:**
- Create: `runtime/actor_scheduler.nim`
- Test: extend `tests/test_actor.nim` with a two-actor scheduling suite.

**Interfaces:**
- Consumes: `Actor`, `actorReady` (Task 3); `cps` `trampoline`, `ContinuationProc`, `running`.
- Produces:
  - `type ActorSched* = object` with `actors*: array[MaxActors, Actor]`, `count*: int`.
  - `const MaxActors* = 64`
  - `proc schedInit*(s: var ActorSched)`
  - `proc schedAdd*(s: var ActorSched; a: Actor)` — registers a whelped+once-trampolined (parked) actor.
  - `proc runOnce*(s: var ActorSched)` — one pass: trampoline every actor whose `actorReady` is true; drop completed (`finished`) actors.
  - Uses `cps.finished(a)` to detect completion and `cps.trampoline` to resume.

- [ ] **Step 1: Write the failing test** — append to `tests/test_actor.nim`:

```nim
import runtime/actor_scheduler

var log2: seq[int]

proc echoer(a: Actor) {.cps: Actor.} =
  receive(a)
  log2.add(int(a.pending.data[0]))

proc testSchedulerRunsReadyActors() =
  var s: ActorSched
  schedInit(s)
  var boxA, boxB: Mailbox[ActorInboxDepth]
  mbInit(boxA); mbInit(boxB)
  var a = Actor(inbox: addr boxA)
  var b = Actor(inbox: addr boxB)
  # whelp + first trampoline (park each on empty inbox)
  schedAdd(s, Actor(trampoline(whelp echoer(a))))
  schedAdd(s, Actor(trampoline(whelp echoer(b))))
  runOnce(s)                      # nothing ready → no logs
  assert log2.len == 0
  discard mbPost(boxB, mkMsg(5))
  runOnce(s)                      # only B ready
  assert log2 == @[5]
  discard mbPost(boxA, mkMsg(9))
  runOnce(s)
  assert log2 == @[5, 9]
  echo "PASS: scheduler runs ready actors"

testSchedulerRunsReadyActors()
```

Note: the exact `Actor(trampoline(...))` cast shape may need adjustment to satisfy cps's continuation typing — if the compiler rejects the cast, store the `Continuation` returned by `trampoline` in the actor's own ref and re-trampoline that. Resolve by matching `test_cps_eval.nim`'s working `c = trampoline(c)` idiom (keep the continuation variable, don't re-wrap).

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/kl/apps/Nim/bin/nim c -r --skipParentCfg --mm:arc --panics:on --path:. -d:noSignalHandler tests/test_actor.nim`
Expected: FAIL — `cannot open file: runtime/actor_scheduler`.

- [ ] **Step 3: Write minimal implementation**

```nim
# runtime/actor_scheduler.nim
# SPDX-License-Identifier: GPL-2.0
## Actor scheduler — re-trampolines parked actors whose inbox filled.
##
## Single-threaded pump: runOnce sweeps registered actors, resuming each that
## actorReady reports runnable, dropping any that finished. This is the soft-RT
## concurrency hub; it scales with actor count, not OS threads (no kstack each).
## MUST compile --mm:arc --panics:on.
import cps
import actor

const MaxActors* = 64

type
  ActorSched* = object
    actors*: array[MaxActors, Actor]
    count*:  int

proc schedInit*(s: var ActorSched) =
  s.count = 0
  for i in 0..<MaxActors: s.actors[i] = nil

proc schedAdd*(s: var ActorSched; a: Actor) =
  assert a != nil, "schedAdd: nil actor"
  if s.count >= MaxActors: return
  s.actors[s.count] = a
  inc s.count

proc compact(s: var ActorSched) =
  ## Remove finished/nil actors, preserving order.
  var w = 0
  for r in 0..<s.count:
    if s.actors[r] != nil and not finished(s.actors[r]):
      s.actors[w] = s.actors[r]; inc w
  for i in w..<s.count: s.actors[i] = nil
  s.count = w

proc runOnce*(s: var ActorSched) =
  ## One scheduling pass: resume every ready actor once.
  for i in 0..<s.count:
    let a = s.actors[i]
    if a != nil and not finished(a) and actorReady(a):
      s.actors[i] = Actor(trampoline(a))
  compact(s)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `/home/kl/apps/Nim/bin/nim c -r --skipParentCfg --mm:arc --panics:on --path:. -d:noSignalHandler tests/test_actor.nim`
Expected: PASS — `PASS: scheduler runs ready actors`.

If the `Actor(trampoline(a))` cast fails to compile, adjust per the Step-1 note: keep continuations as `Continuation` and store back, matching `test_cps_eval.nim`. Re-run until green.

- [ ] **Step 5: Commit**

```bash
git add runtime/actor_scheduler.nim tests/test_actor.nim
git commit -m "runtime: actor scheduler pump over ready mailboxes"
```

---

### Task 5: Reimplement ServerChan as a Mailbox compat shim

**Files:**
- Modify: `ipc/server_chan.nim`
- Test: existing `tests/test_*` that exercise ServerChan must stay green (find them first: `grep -rl serverChan tests/`).

**Interfaces:**
- Consumes: `Mailbox`, `mbPost`, `mbTryRecv`, `mailbox_registry` (Tasks 1–2).
- Produces: UNCHANGED public API — `ServerChan`, `ServerMsg`, `MaybeMsg`, `serverChanCreate`, `serverChanPost`, `serverChanRecv`, `serverChanRegister`, `serverChanFind`, `serverChanRegistryInit`, `serverMsgFromMp`, `serverMsgToMp`. Internally these now delegate to Mailbox/registry. `ServerMsg` becomes a type alias of `MailMsg`; `ServerChanDepth` maps to a `Mailbox[16]`.

- [ ] **Step 1: Find the ServerChan callers/tests**

Run: `grep -rln "serverChan\|ServerChan\|ServerMsg" --include=*.nim . | grep -v ipc/server_chan.nim`
Record the list; these must all still compile after the shim.

- [ ] **Step 2: Rewrite server_chan.nim as a shim (show full new file)**

```nim
# SPDX-License-Identifier: GPL-2.0
## Server Channel — compatibility shim over the unified Mailbox primitive.
##
## Historically a bespoke MPSC ring; now a thin adapter so existing servers keep
## their serverChanPost/Recv API while the storage is the shared Mailbox. New
## code should prefer ipc/mailbox + runtime/actor directly.
import mailbox
import mailbox_registry
export mailbox        # ServerMsg alias + MaybeMsg live on top of MailMsg

const
  ServerChanDepth*   = 16
  ServerMsgMaxLen*   = MailMsgMax
  ServerChanNameLen* = MbNameLen
  MaxServerChans*    = MaxMailboxes

type
  ServerMsg* = MailMsg
  MaybeMsg*  = MaybeMail
  ServerChan* = object
    name*: array[ServerChanNameLen, char]
    mb*:   Mailbox[ServerChanDepth]

proc serverChanRegistryInit*() = mbRegistryInit()

proc fillName(dst: var array[ServerChanNameLen, char]; src: string) =
  let lim = if src.len < ServerChanNameLen - 1: src.len else: ServerChanNameLen - 1
  for i in 0..<lim: dst[i] = src[i]
  dst[lim] = '\0'

proc serverChanCreate*(name: string): ServerChan =
  mbInit(result.mb)
  fillName(result.name, name)

proc serverChanName*(ch: ServerChan): string =
  var s = ""
  for c in ch.name:
    if c == '\0': break
    s.add(c)
  s

proc serverChanPost*(ch: var ServerChan; msg: ServerMsg): bool =
  mbPost(ch.mb, msg)

proc serverChanRecv*(ch: var ServerChan): MaybeMsg =
  mbTryRecv(ch.mb)

proc scPostThunk(mb: pointer; msg: MailMsg): bool {.nimcall.} =
  mbPost(cast[ptr Mailbox[ServerChanDepth]](mb)[], msg)
proc scRecvThunk(mb: pointer): MaybeMail {.nimcall.} =
  mbTryRecv(cast[ptr Mailbox[ServerChanDepth]](mb)[])

proc serverChanRegister*(ch: var ServerChan) =
  mbRegister(serverChanName(ch), addr ch.mb, scPostThunk, scRecvThunk)

proc serverChanFind*(name: string): ptr MailboxRef =
  mbFind(name)

# ── MsgPack helpers (unchanged behaviour) ─────────────────────────────────────
import ../kernel/ipc/msgpack_chan

proc serverMsgFromMp*(buf: MpBuf): ServerMsg =
  let n = if buf.pos < ServerMsgMaxLen: buf.pos else: ServerMsgMaxLen
  result.len = uint16(n)
  for i in 0 ..< n: result.data[i] = buf.data[i]

proc serverMsgToMp*(msg: ServerMsg): MpBuf =
  result.pos = 0
  let n = if int(msg.len) < 256: int(msg.len) else: 255
  for i in 0 ..< n: result.data[i] = msg.data[i]
```

NOTE: `serverChanFind` return type changes from `ptr ServerChan` to `ptr MailboxRef`. Check the Step-1 caller list: if any caller dereferences the old `ptr ServerChan` to call `serverChanRecv`, migrate it to use `mbPostByName`/the ref's thunks. If callers only test for nil (registration check), no change needed. Fix each caller found.

- [ ] **Step 3: Build all three models**

Run: `make build 2>&1 | grep -E "error:|Error" | grep -v Warning | head`
Expected: empty (no errors). Fix any caller breakage from the `serverChanFind` type change.

- [ ] **Step 4: Run full test suite**

Run: `make test 2>&1 | grep -iE "error|fail|passed" | grep -v Warning | tail`
Expected: `=== All tests passed ===`.

- [ ] **Step 5: Commit**

```bash
git add ipc/server_chan.nim  # + any migrated callers
git commit -m "ipc: ServerChan becomes a Mailbox compat shim"
```

---

### Task 6: audio_server becomes the reference actor

**Files:**
- Modify: `servers/media/audio_server_elf.nim`
- Test: existing `tests/test_audio_logic.nim` stays green (logic unchanged; only the shell's receive loop changes).

**Interfaces:**
- Consumes: `Actor`, `receive` (Task 3); `Mailbox` (Task 1); existing `audio_logic` (`audioHandle`, `MediaRequest`, `AudioIface`).
- Produces: audio_server's `appMain` builds an `Actor` whose body loops `receive()` → decode `MediaRequest` from `a.pending` → `audioHandle` → reply. The hand-rolled `nimixChanRecv` poll loop is replaced by the actor receive loop. Public entry `appMain*` unchanged.

- [ ] **Step 1: Rewrite the receive loop as an actor body**

Replace the `while true: nimixChanRecv(...)` loop in `appMain` with an actor. Because the ELF runs ring-3 with its own trampoline, the server drives its own single actor via `whelp` + a local `trampoline` pump (the kernel-side actor_scheduler is for in-kernel actors; the ELF hosts one actor and pumps it against its inbox filled by `nimixChanRecv`). Show the new `appMain`:

```nim
proc serverBody(a: Actor) {.cps: Actor.} =
  let iface = AudioIface(play: elfPlay, drain: elfDrain, wait: elfWait,
                         stop: elfStop, volume: elfVolume)
  while true:
    receive(a)                                  # suspends until inbox has a msg
    if a.pending.len >= uint16(MediaMsgLen):
      let req = decodeRequest(cast[ptr UncheckedArray[uint8]](addr a.pending.data[0]))
      let reply = audioHandle(iface, req)
      var repBuf: array[16, uint8]
      let rn = encodeReply(reply, cast[ptr UncheckedArray[uint8]](addr repBuf[0]))
      discard nimixChanSend("media", addr repBuf[0], rn)

proc appMain*() {.exportc.} =
  write("audio_server: starting\n")
  var inbox: Mailbox[ActorInboxDepth]
  mbInit(inbox)
  var a = Actor(inbox: addr inbox)
  var c = whelp serverBody(a)
  write("audio_server: ready on 'media' channel\n")
  var raw: array[MailMsgMax, uint8]
  while true:
    # Bridge: pull from the kernel channel into the actor inbox, then pump.
    let n = nimixChanRecv("media", addr raw[0], raw.len)
    if n > 0:
      var m: MailMsg
      m.len = uint16(min(n, MailMsgMax))
      for i in 0..<int(m.len): m.data[i] = raw[i]
      discard mbPost(inbox, m)
    c = trampoline(c)      # resume the actor if its inbox has work
    if n <= 0: nimixYield()
```

Add imports at the top: `import ../../ipc/mailbox` and `import ../../runtime/actor` and `import cps`.

CONSTRAINT: this file now needs `--mm:arc --panics:on` to build (CPS). Check `apps/`/server ELF build flags in the Makefile; the ELF apps already build with a specific mm — if they are `--mm:arc` already (dispatch_logic uses cps), no change; if not, the audio_server ELF target needs its own arc flags. Inspect and adjust the ELF build rule for this server.

- [ ] **Step 2: Build the audio_server ELF**

Run: `make build 2>&1 | grep -E "error:|Error|audio_server" | grep -v Warning | head`
Expected: empty. If CPS/mm errors appear, fix the ELF build flags for this target (arc+panics).

- [ ] **Step 3: Full suite green**

Run: `make test 2>&1 | grep -iE "error|fail|passed" | grep -v Warning | tail`
Expected: `=== All tests passed ===` (audio_logic unchanged, still 7 cases).

- [ ] **Step 4: Commit**

```bash
git add servers/media/audio_server_elf.nim  # + Makefile if flags changed
git commit -m "audio_server: reference actor with receive-loop"
```

---

### Task 7: Dispatcher becomes an actor; priority queue is its policy layer

**Files:**
- Modify: `servers/dispatch/dispatch_logic.nim`
- Test: existing dispatcher tests stay green (`grep -rl dispatch tests/`); add one case asserting the actor drains its inbox into the priority queue.

**Interfaces:**
- Consumes: `Actor`, `receive` (Task 3); `PriorityQueue`, `pqPush`, `pqPop` (unchanged); `Mailbox` (Task 1).
- Produces: the dispatcher's `ingestRequests` CPS proc receives from its actor inbox (not a raw `recv` poll), decodes a `WireRequest`, classifies, and `pqPush`es. `dispatchRequests` pops by priority and routes via `mbPostByName(target, msg)`. The priority queue is now explicitly the *ordering policy* between the uniform inbox and the uniform outbound post — not a competing queue type.

- [ ] **Step 1: Rewrite ingest as an actor receive loop** — modify the `when not defined(dispatchNoCps)` block:

```nim
proc ingestRequests*(ds: ptr DispatchState; a: Actor) {.cps: Actor.} =
  ## Receive requests from the actor inbox and enqueue them by priority.
  while true:
    receive(a)
    let n = int(a.pending.len)
    if n > 0:
      let wreq = decodeRequest(cast[string](a.pending.data.toOpenArray(0, n-1)))
      var req = DispatchRequest(
        op:        wreq.op,
        callerPid: wreq.pid,
        class:     classifyRequest(wreq.op, false),
        deadline:  assignDeadline(classifyRequest(wreq.op, false), ds.tickNow),
        payloadSlot: -1)
      discard pqPush(ds.queue, req, ds.tickNow)
```

And route outbound via the registry:

```nim
proc dispatchRequests*(ds: ptr DispatchState) {.cps: DispatchCont.} =
  while true:
    var req: DispatchRequest
    if pqPop(ds.queue, req):
      let category = req.op shr 24
      let target = case category
        of 0: "fs"
        of 1: "net"
        of 2: "media"
        of 3: "input"
        else: "log"
      let fwd = encodeRequest(req.op, req.callerPid)
      var m: MailMsg
      m.len = uint16(min(fwd.len, MailMsgMax))
      for i in 0..<int(m.len): m.data[i] = byte(fwd[i])
      discard mbPostByName(target, m)
```

Add `import ../../ipc/mailbox`, `import ../../ipc/mailbox_registry`, `import ../../runtime/actor`.

- [ ] **Step 2: Add a host test** (arc) asserting ingest drains inbox → priority queue. Create `tests/test_dispatch_actor.nim`:

```nim
# SPDX-License-Identifier: GPL-2.0
## Dispatcher actor ingest test. --mm:arc --panics:on.
import ipc/mailbox
import runtime/actor
import servers/dispatch/dispatch_logic
import servers/dispatch/priority_queue
import cps

proc testIngestDrainsToQueue() =
  var ds: DispatchState
  # dispatchInit needs an iface; a stub with no-op fns is fine for ingest.
  # (Fill DispatchIface with nimcall no-ops — see dispatch_kmod for shape.)
  # ... construct ds, inbox, post a WireRequest-encoded msg, trampoline once ...
  # assert ds.queue.count == 1
  echo "PASS: dispatcher ingest drains inbox to priority queue"

testIngestDrainsToQueue()
echo "All dispatch actor tests passed."
```

Fill the elided section using `dispatch_wire.encodeRequest(op, pid)` to build the message and the `dispatch_kmod` iface shape for the no-op stub. Wire into the Makefile arc test list.

- [ ] **Step 3: Build + test**

Run: `make build 2>&1 | grep -E "error:|Error" | grep -v Warning | head` → empty.
Run: `make test 2>&1 | grep -iE "error|fail|passed" | grep -v Warning | tail` → `=== All tests passed ===`.

- [ ] **Step 4: Commit**

```bash
git add servers/dispatch/dispatch_logic.nim tests/test_dispatch_actor.nim Makefile
git commit -m "dispatch: actor ingest; priority queue as ordering policy"
```

---

### Task 8: Virtqueue mailbox-shaped completion reader

**Files:**
- Modify: `drivers/virtio/virtqueue.nim`
- Test: existing `tests/test_virtio.nim` stays green; add a `vqReceive` case.

**Interfaces:**
- Consumes: `virtqueuePop` (unchanged).
- Produces: `proc vqReceive*(vq: var Virtqueue): tuple[found: bool; id: uint32; len: uint32]` — a mailbox-shaped alias so driver completion code reads uniformly (`while vqReceive(...).found`). Thin wrapper; zero behavior change. This documents the convergence: hardware rings expose the same "receive a completion" verb as software mailboxes, without pretending a virtqueue IS a Mailbox (it carries descriptors, not MailMsgs).

- [ ] **Step 1: Add the wrapper + test** in `tests/test_virtio.nim`:

```nim
test "vqReceive mirrors virtqueuePop":
  # Build a Virtqueue with one used entry (reuse existing test setup helpers),
  # then assert vqReceive returns the same (found,id,len) as virtqueuePop would.
  discard  # fill using the existing test_virtio scaffolding
```

- [ ] **Step 2: Implement** in `drivers/virtio/virtqueue.nim` (append):

```nim
proc vqReceive*(vq: var Virtqueue): tuple[found: bool; id: uint32; len: uint32] =
  ## Mailbox-shaped completion read: "receive" the next finished buffer, if any.
  ## Uniform verb over the used ring — same shape as a software mailbox recv.
  virtqueuePop(vq)
```

- [ ] **Step 3: Build + test**

Run: `make test 2>&1 | grep -iE "error|fail|passed|virtio" | grep -v Warning | tail`
Expected: virtio tests pass; `=== All tests passed ===`.

- [ ] **Step 4: Commit**

```bash
git add drivers/virtio/virtqueue.nim tests/test_virtio.nim
git commit -m "virtqueue: vqReceive mailbox-shaped completion reader"
```

---

### Task 9: Document the model in DECISIONS.md

**Files:**
- Modify: `DECISIONS.md`

- [ ] **Step 1: Append a decision entry**

```markdown
### Actor/Mailbox unification (2026-07-01)
- **Decision**: One queue primitive — `ipc/mailbox.nim::Mailbox[N]` (bounded MPSC
  ring). Servers are actors (`runtime/actor.nim`): a CPS continuation bound to one
  mailbox, blocking on `receive()` (a cpsMagic suspend-point). The actor scheduler
  (`runtime/actor_scheduler.nim`) re-trampolines a parked actor when its inbox fills.
- **Rationale**: Uniform mailbox = no locks (single-CPU), no polling, scales with
  actor count not OS threads. Matches the single-threaded CPS dispatcher axiom and
  the "very large scale concurrency" goal.
- **Layering**: The dispatcher's priority queue is NOT a competing queue type — it
  is the *ordering policy* applied between a uniform inbox (receive) and uniform
  outbound posts (mbPostByName). Priority is scheduling, mailbox is transport.
- **Virtqueues** stay hardware-specific (they carry descriptors, not MailMsgs) but
  expose `vqReceive` so completion code reads with the same "receive" verb.
- **Constraint**: actor/CPS code compiles `--mm:arc --panics:on` (nim-cps); pure
  data primitives (Mailbox) stay `--mm:refc`-testable. ServerChan is now a compat
  shim over Mailbox (`ipc/server_chan.nim`).
- **Deferred**: SMP spinlock on mailbox head/tail; per-actor priority; fair
  scheduling across actors (runOnce is round-robin today).
```

- [ ] **Step 2: Commit**

```bash
git add DECISIONS.md
git commit -m "docs: record actor/mailbox unification decision"
```

---

## Self-Review

**Spec coverage:**
- "all queues should be like [actor/mailbox]" → Task 1 (Mailbox primitive), Task 5 (ServerChan shim), Task 7 (dispatcher priority-as-policy over mailbox), Task 8 (virtqueue receive verb). Covered.
- "servers behave in this way too" → Task 3 (Actor), Task 6 (audio_server reference actor), Task 7 (dispatcher actor). Covered.
- "CPS coroutines substrate" → Task 3/4 built on proven `test_cps_eval.nim` primitives. Covered.
- "full unification" → all three shapes (ServerChan, priority queue, virtqueue) addressed. Covered.
- "large-scale concurrency / performance" → actor scheduler scales with actor count, no kstack-per-actor; documented in Task 9. Covered.

**Placeholder scan:** Task 7 Step 2 and Task 8 Step 1 leave test-body sections to fill against existing scaffolding — these reference concrete existing helpers (`encodeRequest`, `dispatch_kmod` iface shape, `test_virtio` setup) rather than inventing APIs. Flagged inline as "fill using X"; acceptable because the surrounding assertions and the API to call are specified. All implementation code blocks are complete.

**Type consistency:** `MailMsg`/`MaybeMail`/`Mailbox[N]` names consistent Tasks 1→8. `Actor.inbox: ptr Mailbox[ActorInboxDepth]` and `receive*(a: Actor): Actor {.cpsMagic.}` consistent Tasks 3→7. `mbPostByName(name, msg)` consistent Tasks 2→7. `serverChanFind` return-type change (`ptr ServerChan` → `ptr MailboxRef`) explicitly flagged in Task 5 with a caller-migration step.

**Open risk (verify during execution):** the exact cps continuation cast in Task 4 (`Actor(trampoline(a))`) and the ELF-side actor pump in Task 6 depend on nim-cps typing that only `test_cps_eval.nim` proves at the basic level. Both tasks include a fallback note ("keep the continuation variable, match test_cps_eval idiom"). If casts fight the compiler, the working reference is the proven `c = trampoline(c)` loop.
