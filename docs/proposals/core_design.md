# NimixOS core design: the structure everything else fills in (PROPOSED, for the human to correct)

Status: **PROPOSED 2026-11-14**, drafted from the human's statements in dialogue (quoted where they
set a rule). It is deliberately short: only what decides *what is possible, what is fast, where
things physically happen, who has authority and how the system works*. Everything not listed here is
fill-in that must not change this structure.

## 0. The principles (the human's, this session)

1. **The design dictates**: what is possible and what is not, what is fast, where things physically
   happen, who has authority, how the system works. Crucial decisions are *mechanisms*, not
   conventions; the rest is filled in part by part without changing the structure.
2. **Client-server by layers.** Servers are isolated and each provides abilities in its own
   domain (its own layer). Clients are the user-facing apps; they link a **library** that defines the
   protocol.
3. **Mechanisms are library code.** The kernel is a composition of mechanism libraries; a driver is a
   module of it ("mini-kernel" parts that touch hardware). Servers hold no driver or hardware code:
   each is the **single client** of the hardware-facing part it fronts.
4. **Drivers: userspace if it performs the same, else in the kernel**, but always *conceptually*
   separate as modules. No physical separation mechanism is required between kernel-space modules.
5. **The contract is the API, the library is an SDK** (the human's REST analogy). A client may speak the
   wire protocol without the library; what it cannot do is get anything outside the contract, because
   the servers enforce it and the dispatcher funnels it. The library gives idiomatic client code and
   hardening (unique ids, sequence checks); it adds no authority and is not the boundary.
7. **The dispatcher stands as designed** (VISION goal 3, axiom 1): the convergence point where QoS,
   authorization, discovery and session brokering happen, so features land once for every service.
6. **Everything written is useful in all three models** (SASOS, micro, monolithic), though the main
   line favours micro. A library earns its place on its own merits, whatever architecture results.

## 1. Roles

```
 app ──links──▶ client library (SDK over the contract) ──▶ dispatcher ──brokers──▶ server   (isolated domain)
        (or speaks the wire protocol itself)                (QoS, authz,   session        │ sole client of
                                                             discovery)  ┌─direct ring─▶  ▼
                                                                         │       device module (hardware-facing part)
                                      control plane (REST-like) via dispatcher; streams (frames, audio)
                                      flow on the brokered session, like an upgraded connection
 kernel = mechanism libraries (scheduling, memory, handles, transport, ...)
          composed per model; device modules sit in it OR run as servers (placement, §3)
```

A **module** is the unit of everything below: a small interface, an authority rule, a stated cost,
host-testable, and **no assumption about where it runs**. A *model* is a composition of modules; a
*placement* is which modules run in the kernel and which in their own domain.

## 2. The essential mechanisms

Each: what it fixes, the invariant, how it is tested, and where we are.

### M1. Authority: handles are the only way to act
- Every action is authorized by a **handle or capability token** held by the caller. **Names are
  addresses; tokens are authority** (a channel is found by name, used only with a token, received only
  by its creator's capability). No ambient topics, no first-come ownership. Rights are granted at spawn
  or by the dispatcher, delegable, revocable, and die with the holder.
- **The kernel stamps the sender** (pid, and the handle used) on every message. Authentication comes from
  the kernel; a library-assigned id is hardening only (point 5), never identity.
- *Invariant:* no operation succeeds on a name alone; every exclusive resource (display, input, a
  device module) has exactly one holder, released on its death.
- *Today:* the gated path exists (`capSend` needs a `capIpc` token; receive needs the creator's
  capability; buffers are handle-based). **Ungated shortcuts** to retire: plain `chanSend`, event
  topics (`input` readable by anyone), and display ownership by first present. A name can still be
  squatted by whoever creates it first; the dispatcher's discovery closes that.

### M2. Modules and placement: structure is fixed, location is a measured choice
- A device module is used through a **device port**: a small interface with **no shared mutable state,
  no pointers across it, data by ownership/handle**. Because of that it has two transports and the
  client is written once: a **direct call** when co-located in the kernel, a **message** when it runs
  as a server. Same code, same tests, different cost.
- **Default placement is the microkernel's** (userspace for everything not inherently privileged:
  scheduling, page tables, interrupts, the capability check, transport). A module runs in the kernel
  only with a **recorded, measured reason** (the same rule VISION uses for rendering exceptions).
- Placement per model is data (the residency map), not code.
- *Invariant:* no module reaches into another's internals; only ports. Dependency graph is acyclic.
- *Accepted consequence:* a defect in a kernel-placed module is a kernel stop (as the mouse bug was);
  no extra containment mechanism is required. A cheap per-model option (catch the defect at the port
  and fail the device) may be added, but is not part of the structure.
- *Today:* modules exist as libraries (ipc, buffers, gfx, term, input keymap, clock, display checks...);
  device ports do not yet exist: drivers are called directly by name.

### M3. Data movement: ownership, in batches
- Control is small messages; bulk data moves by **ownership** (owned/sealed, move/lend), never shared
  mutable memory (frozen: `bulk_data.md`). Streams are **sessions** whose steady state is batched
  (rings): the fast path makes about one kernel call per batch, not per item.
- *Invariant:* a cost is a stated count (kernel calls per frame, copies per byte), gated in CI.
- *Today:* ownership and the host-side ring are built and tested; the ring syscalls and a small-buffer
  lane (every buffer costs a 2 MB block) are not.

### M4. Time: waiting and waking
- A task can block until a source is ready or a deadline passes; IRQs wake by delivering to a handle;
  sub-tick timers exist. Responsiveness is a property of this layer, not of each server.
- *Invariant:* no server polls on a timer to find work. *Today:* everything polls on the 10 ms tick.

### M5. Resources: charged to an owner
- Every byte, handle, buffer and session is charged to a budget; **charges follow ownership**; a server
  never allocates on a client's behalf outside the session budget it was granted.
- *Today:* buffer budgets exist (32 MB per task); arena sizing (V4b) and session caps are open.

### M6. Failure: contained where a domain exists, always cleaned up
- Death of a task releases everything it holds (handles, exclusive bindings, buffers, channels, the
  display) and tells its peers. A server's death unbinds it from its device module, which is reset.
- *Invariant:* no resource outlives its owner. *Today:* tasks' buffers, display and input grab are
  released on exit; channels and capabilities are not yet (a listed seam).

### M7. Services and protocols: the contract is the API (like REST)
- Each service's **wire contract** is its public interface, written once (a PROPOSAL, not yet agreed:
  from that description generate the server stub, the SDK and the validation, so they cannot drift;
  open question #3, schema location, resolves here). Control plane = MsgPack, data plane = flat
  records or buffer handles (agreed 2026-10-26). A client may skip the SDK; it cannot skip the
  contract, because the server validates every message as hostile (the draw protocol already does)
  and the dispatcher controls what handles a client gets.
- The SDK negotiates a **version** in `hello` and adds hardening (session ids, sequence numbers); it
  confers no authority.
- *Today:* hand-written record codecs (`bridge/`, `libnimix`).

### M8. The convergence point: the dispatcher
- All control-plane requests funnel through the dispatcher (CPS, single actor, priority queue with
  aging, QoS classes realtime/interactive/normal/background). It is the one place that authorizes
  (kernel-stamped sender plus capability), discovers (which service, which handle), applies QoS and
  quotas, and **brokers sessions**: for a stream it checks the capability, picks the QoS class, ring
  depth and budget once, then hands each side one end of a ring; it can resize, reprioritise or revoke
  it later. Steady-state data does not pass through it (agreed, `bulk_data.md` decision 2).
- *Invariant:* a client reaches a server only through a handle the dispatcher brokered. A feature that
  applies to every service (rate limits, tracing, priorities) is added here, once.
- *Today:* Stage 1 built (actor run loop, strict wire decode, benchmark about 2.7M requests/s). Not
  in the app path: apps talk to servers directly (STATE). Stage 2 (reply correlation, capability
  gating, session brokering, discovery) is the work this skeleton needs.

## 3. Placement: the matrix (the residency map, restated)

"Default" is the microkernel placement. A cell other than the default is a measured exception.

| component | micro (default) | monolithic | SASOS | until then |
|-----------|-----------------|------------|-------|------------|
| scheduler, memory, handles, transport | kernel | kernel | kernel | n/a |
| device modules (gpu, input, blk, net, snd) | **userspace server if as fast, else kernel module** | kernel modules | kernel modules | all in kernel today; needs device ports and (for userspace) interrupt/MMIO/DMA handles |
| fs, net stack, audio mixing, render, wm, console | servers | servers or linked | servers or linked | fs_server exists; others kernel today |
| client libraries | linked into apps | same | same | `libnimix`, the raylib bridge |

The two device-module transports (M2) are what let us *measure* before moving anything.

## 4. What the structure forbids (each should become a failing test)

1. An operation authorized by a name alone, or a client reaching a server without a brokered handle.
2. A second holder of an exclusive resource.
3. Mutable memory visible to two tasks.
4. A device touched except through its module's port.
5. A server holding a hardware address or interrupt.
6. Policy in the kernel (what to draw, where to focus, who may open which file).
7. A cost claim without a count.
8. A module depending on its own caller (a cycle).

## 5. How today's work maps on

| existing / proposed | becomes |
|---------------------|---------|
| buffers + rings (frozen) | M3 as specified |
| syscall gate argument table (V14) | M1's enforcement for the interim direct syscalls; the table shrinks as services replace calls |
| display ABI v1/v2, `input` topic | the **first device ports** to define (display, input); today ambient, to become exclusive-client handles (V6 D3/D4) |
| `libnimix`, raylib bridge | client libraries (M7), with the interim kernel calls behind them |
| V6 decisions | D1 -> M3; D2 -> M4; D3, D4 -> M1; **D7 -> M8 (dispatcher brokers; my earlier "direct" pick is withdrawn)**; D10 -> M5; D5, D8, D9, D11, D12 stay render-server local |
| residency map R0-R8 | remains the microkernel-model target; each move needs a device port first, then a measurement |

## 6. Decisions this structure needs from the human

1. **Per-task address spaces (Stage B)** decide who can touch what in memory at all, and whether
   "isolated domains" is enforced by hardware or by the type system in a given model. It belongs in M2
   and is the most expensive to change later.
2. **The device-port interface rules** (no pointers, no shared state, handles and ownership): is that
   the line, and is "message or direct call, same code" the right way to keep placement open?
3. ~~How does an app obtain its first handles?~~ **Answered by the existing design:** the dispatcher
   (discovery and capability grants). What remains is how a program obtains its *first* handle to the
   dispatcher: the spawner hands it over at spawn (my assumption).
4. **Order**: the skeleton (M1 rights, M8 dispatcher Stage 2, M4 wait/wake, M3 rings and small buffers,
   then the first device ports for display and input) *before* the render server's executor. Agree?
   Assumptions awaiting the human: the "hardware-related server" is the device module (server or kernel
   module) fronted by a domain server; V6 test clients are ELF until the WASM host (V8) exists.
5. **SMP** touches M1, M4, M6 (per-CPU state); declare it out of the structure for now, or in?

## 7. What this document is not
It does not freeze any interface; it names the mechanisms and invariants that interfaces must obey.
Each mechanism gets its own proposal and tests when it is built, in the order you set in §6.4.
