# Capabilities: handles, rights, and static separation (PROPOSED)

Status: **PROPOSED 2026-11-14.** This is mechanism M1 of `core_design.md`, written after the human's
direction: *use the proper model from Zircon and seL4, with performance hints from Singularity; avoid
hurting performance; capabilities are an isolation and separation mechanism that decides what apps
may access so they cannot take data from other apps; there is no one to revoke dynamically; malicious
intent (hacking, viruses, keylogging, ...) must be fully restricted.* The human delegated the details
to me; I flag the few places that are policy and therefore theirs.

## 1. The model in one paragraph

Authority is a **handle**: an entry in the *calling task's own table*, naming a kernel object together
with a set of **rights**. A task can do something to an object only by presenting a handle it holds
whose rights allow it. Handles cannot be forged (the number means nothing outside the holder's own
table), cannot be created from nothing (**conservation**: a task can only pass on, narrow or use what
it already holds), and are all released when the task dies. Nothing is looked up by name to *gain*
authority. At spawn, a task receives exactly the handles its spawner gives it, and that set is its
whole world. There is no dynamic revocation machinery.

## 2. Prior art, and what we take and drop

| | what it has | we take | we drop |
|---|-------------|---------|---------|
| **Zircon** (Fuchsia) | per-process handle table; kernel objects with refcounts; a rights bitmask on each handle; `duplicate` (with fewer rights), `replace`, `close`; handles **move** across channels; handle values are not plain indices; all syscalls act on handles; no revocation tree; filesystem access through per-component namespaces | the whole shape: table, rights, move/duplicate, peer-closed, namespaces, no revocation | jobs and policy objects (we have no job tree yet) |
| **seL4** | capabilities = (object, rights, **badge**) in a CSpace; `Mint` derives a capability with fewer rights and a badge; the receiver of a message learns the **badge** of the endpoint it was sent through; the initial task holds all authority and hands it out; authority cannot be created | **badges** (the server learns who is calling without any lookup and without a pid); the initial-task rule; derive-with-fewer-rights | the capability derivation tree and `Revoke`; untyped memory and retype (our memory is buffers) |
| **Singularity** | software-isolated processes in one address space; channels with typed **contracts**; ownership-transfer exchange heap; manifests **declare** a program's needs, checked at install, not per call | **static declaration, checked once** (the app manifest, resolved at spawn); ownership-based zero-copy (already: buffers); in the SASOS model a handle can be a typed reference | contract verification (a later tool, not a mechanism) |

## 3. Mechanism

### 3.1 The table and the check (the hot path)
- Each task owns an array of entries `{object ref, rights, badge, type tag}`; a **handle value** is the
  entry index combined with a per-slot generation (so a stale or guessed value fails, as in Zircon).
- A syscall naming a handle does: one array index, one generation compare, one type check, one
  `rights & needed` test. No hash, no lock (the table is mutated only by its owner or by the delivery
  of a message into it), no allocation. A few nanoseconds, and none of it is paid per byte: handles are
  presented **per operation on a session, not per datum**.
- The object reference is held in the entry (refcounted object); the kernel does no name lookup on the
  hot path.

### 3.2 Objects (what a handle can name)
| object | notes |
|--------|-------|
| **channel endpoint** | one end of a message pipe (small messages + handles); a pair is created together; closing one end makes the other see *peer closed* |
| **buffer** | exists (`ipc/buffers`); its per-task table folds into this one |
| **device port client** | the *single client* binding to a device module (display, input, blk, ...); exclusive: a second bind fails; released on death |
| **wait/notification** | a source a task can block on; interrupts and events wake through it (mechanism M4) |
| **process** | the right to spawn, to wait for a child, to kill it |
| **dispatcher endpoint** | a channel endpoint with a badge = the app's identity |

### 3.3 Rights
A small bitmask per handle: `READ WRITE MAP TRANSFER DUPLICATE WAIT SIGNAL BIND SPAWN` (exact set
decided with the code). `duplicate` can only **remove** rights. `transfer` moves the handle out of
the sender's table and into the receiver's when the message is delivered (the buffers mechanism, now
for every object).

### 3.4 Badges: who is calling
When the dispatcher or a server creates a client's endpoint, it stamps a **badge** (a 64-bit value it
chooses: a session id) on the client's handle. Every message through that handle reaches the server
carrying the badge, written by the kernel. So:
- the server identifies its caller with **no lookup, no pid, nothing the client can forge**;
- the library's "unique ids" (the human's hardening idea) are no longer needed for identity; they remain
  useful as sequence numbers;
- a client cannot change its badge; it can only duplicate its handle (same badge) or pass it on.

### 3.5 Spawn: the whole world is what you are given
`spawn(image, handles[])`: the child receives the listed handles and nothing else, and the spawner may
list only handles it holds (narrowed if it wishes). There is no ambient namespace: no global channel
names, no `input` topic, no "first present wins". The first task (init) holds the root handles
(device ports, process rights) and hands them out.

**What an app gets is decided by a static policy**, applied once at spawn (the Singularity manifest
idea): the app's manifest declares what it needs (a dispatcher endpoint, a file-system scope, a
network right, a window); the launcher grants the subset the policy allows. The kernel only enforces
conservation; the policy lives in the launcher, as a file the human can read.

### 3.6 How an app reaches services
The launcher gives every normal app a **dispatcher endpoint** (badged with the app's identity), as a
program gets its standard input. That is the "global proxy" the human described, with the property
that a program not given the handle cannot reach it. From there the dispatcher brokers further handles
(session endpoints to the file server, the render server, ...): it holds the capability to create them,
the client holds only what it was granted. The file server receives a **directory handle** (a scope),
not a path: the app can name files only inside the scope it was given (the Zircon namespace idea), which
is also the answer to the confused-deputy problem: authority travels with the request as a handle,
never as a name the server resolves with its own privileges.

### 3.7 Revocation: what we keep, what we drop
- **Keep:** *close* (drop my handle), *death* (a dead task's table is closed, all its objects
  released, peers see *peer closed*), and *kill* (the human's or the supervisor's ultimate revocation).
- **Drop:** derivation trees, `Revoke`, leases and timeouts. If a server needs to cut one client, it
  closes its end of that client's endpoint; the client's handle then reports *peer closed*. This is
  Zircon's answer and needs no tree.

## 4. What it prevents (the threats the human named)

| threat | how it is stopped |
|--------|-------------------|
| **keylogging** | input is a device port with one client (the input path); no other task can obtain a handle to it, and there is no topic to subscribe to. An app receives only the events the focused-window server forwards on its own endpoint. |
| **reading another app's data** | there is no shared mutable memory (buffers: owned, moved, lent, sealed); another app's buffers are not in your table; other tasks' regions are not mapped for you (per-task address spaces strengthen this; see §6). |
| **a virus spawning or spreading** | spawning is a right (a handle), not ambient; a program that was not given it cannot start another. Even if it can, the child gets only a subset of the parent's handles. |
| **reading or writing files it should not** | the app holds a directory scope, not the filesystem; paths cannot escape the scope. |
| **network** | only with a network handle; an app without one has no way to name the network server. |
| **screen capture or overlay** | only the display's single client draws; screenshots are a capability the render server may grant. |
| **forging authority by guessing** | handle values are generation-tagged indices into your own table; abifuzz-style tests throw random values at every syscall. |
| **raw kernel access** | the syscall set shrinks to handle operations, channel I/O, memory and wait; the checks (V14) stay for pointers. |

**What it does not stop** (stated so nobody assumes otherwise): a bug inside the TCB (kernel modules,
the capability code itself); a user or launcher policy that grants too much; timing and other side
channels; a malicious *server* misusing the authority it legitimately holds; and bugs in the memory
isolation underneath (this mechanism assumes it).

## 5. Performance (the human's constraint)

- The hot path is §3.1: a handful of loads and compares, the same order as a file-descriptor lookup.
- **Authorization happens when a session is created, not per request.** After brokering, a stream runs
  on its ring with no per-item check (the cost the dispatcher already moves to setup, `bulk_data.md`).
- Manifests are resolved once at spawn, not consulted at run time.
- Badges cost one word copy per message.
- No lock on lookup; the per-task table is SMP-friendly by construction (only its owner and message
  delivery write it).
- In the **SASOS model** (single address space, type-safe) a handle can be a typed reference and a
  channel send an ordinary call: the same API, no table, the Singularity cost profile. In the
  microkernel model the table lookup is the price; in monolithic, kernel modules may use the same
  handles by direct call.
- A benchmark gates it: handle lookup + a trivial channel round trip are measured before and after the
  migration (`rlbench`-style baseline), and the budgets in VISION apply.

## 6. What the human should decide (policy and structure; the rest I decide)

1. **Where policy lives**: a per-app manifest read by the launcher, with a system policy that can
   narrow it. Is that the right place, and in what form (a file per app, a system file)?
2. **File scoping**: each app sees a directory scope (a private home plus shared read-only areas), not
   the whole disk. This changes how `ls`, `cat` and the shell behave for apps.
3. **Memory isolation underneath**: "cannot take data from other apps" also needs per-task address
   spaces (or the type system in SASOS). Regions and buffers are enforced per task today; the rest of
   the address space is shared. How far must this go before the capability story is believable?
4. **What the shell is**: the shell is a kernel task holding every right today. Until it is a
   userspace program (R6), it is the one ambient authority; keep that, accepted and listed?

## 7. Migration (small slices; each ends with a test)

| slice | content | test |
|-------|---------|------|
| **C1 table** | pure `handle_table` module: entries, generations, rights, duplicate (narrow only), move, close-all; unify the buffers table | property tests (random sequences: no forged handle succeeds, rights only narrow, closing releases everything) in the host suite |
| **C2 channels** | channel endpoint pairs replacing named `ServerChan` + `capSend`; badges; peer-closed | pairs, transfer of handles in messages, badge stamping, hostile values via `abifuzz` |
| **C3 spawn** | `spawn(image, handles[])` and a launcher policy file; remove ambient `chanSend`, event topics, first-present display | a test app given no handles can do nothing; an app given only a dispatcher endpoint cannot read input, open files outside its scope, or spawn |
| **C4 device ports** | display and input become single-client bindings; the `input` topic goes away | a second client is refused; death releases; a keylogger test app gets nothing |
| **C5 scope** | file-server directory handles | path escape attempts fail |
| **C6 the gate** | the syscall set shrinks to handle-based operations | the syscall table test lists nothing that takes a name |

C1 and the benchmark come first; they are pure and cheap and settle the cost question before anything
depends on it. The dispatcher Stage 2 design follows C2 (badges and endpoint pairs are what it brokers).

## 8. Open points I will settle while building

Exact rights set; handle value layout (index bits, generation bits); table size per task (grow on
demand, bounded by the budget); whether a duplicated handle shares or copies the badge (shares);
how `peer closed` is reported (a sticky signal on the wait object).
