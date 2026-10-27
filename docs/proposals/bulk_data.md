# Bulk data: buffers, handles, rings — proposal v2 (NOT frozen)

Status: **FROZEN 2026-10-27 (v2)** — all decisions agreed; API `ipc/buffers.nim`, implemented by `subprojects/buffers/`. The requirement: one general, explicit,
formal mechanism for big data, with no copying through messages and no
unsafe shared memory. Decisions needed are in §10.

v2 aligns v1 with VISION's axioms and performance model:
- control goes through the dispatcher, data never does (§4);
- one kernel call per *batch*, not per buffer (§5);
- small payloads are copied and large ones moved: two lanes, chosen by size (§3);
- memory has a budget and the requester pays (§6);
- WASM apps, the default kind of app, are first-class (§7);
- wakeups are actor mailbox messages; the existing `ipc/mailbox` and
  `ipc/mpsc_ring` are reused (§5);
- each kernel model pays only what its isolation needs (§8).

## 1. Today (tested 2026-10-27)

Region capabilities existed but were unsafe. Three holes are fixed (see
DECISIONS §Region capabilities). This also restored the VISION axiom
*"region ref count reaches zero before regionFree"*, which the code had
violated. Still open: rights aren't enforced on access, and tokens are
global and guessable. This proposal closes both.

## 2. The rule (formal core)

> **Mutable memory is never shared.** A buffer is **owned** (exactly one
> task may access it) or **sealed** (immutable; any holder may read).
> Ownership changes only by explicit transfer (move or lend).
> The only memory two tasks touch concurrently is a **ring**'s
> descriptor area. Its layout and protocol live in one audited module, and
> it never carries bulk data, only descriptors and small inline payloads.

This is aliasing XOR mutability (Rust), enforced by the OS: page rights in
the ring-3 models, and the type system in SASOS (§8).

## 3. Two lanes, chosen by size (performance by design)

| lane | size | path | cost |
|------|------|------|------|
| **inline** | ≤ 240 B (`MailMsgMax` minus header) | copied inside the message/ring slot | one cache-hot copy; no mapping change, no handle |
| **buffer** | anything larger | a buffer **moved** or **lent**; the message carries `BufRef{handle, offset, len}` | zero copies; one batched ownership flip (§5) |

Copying a few hundred bytes is cheaper than any page-table change, and
moving megabytes is cheaper than copying them. The library picks the lane,
so apps never choose by hand.

## 4. Control vs data plane — the dispatcher sees handles, never bytes

VISION: *apps never call I/O directly; control plane = MsgPack, data plane
= FlatBuffers or region token.* Buffers formalise "region token":

```
app ──MsgPack request + handles[]──▶ dispatcher ──(QoS, cap check, budget)──▶ server
                                      holds handles in TRANSIT: no map right,
                                      forwards them by index, never touches data
```

- Handles travel out-of-band in a message's `handles[]` array (as Fuchsia
  FIDL does). The kernel moves them from the sender's handle table to the
  receiver's when the message is delivered. Payload descriptors inside the
  FlatBuffers/MsgPack body refer to `handles[i]`.
- The dispatcher can **schedule by size**: it sees `len`, not the data, so
  QoS can account for bulk without reading it.
- **Sessions** for streams (frames, audio, input, packets): the dispatcher
  brokers a session once (capability check, QoS class, ring depth, budget),
  then hands each side one end of a session ring. The steady-state stream
  flows on that ring, and the dispatcher stays the policy owner: it can
  resize, reprioritise or revoke the session at any time. This keeps the
  dispatcher out of the 60 fps path without violating "all I/O goes
  through dispatcher" (decision 2).

## 5. Rings: batched ownership, actor wakeups

A **session ring** is built from `ipc/mpsc_ring` (Vyukov, lock-free,
already tested). The single-producer case is a degenerate MPSC. Slots
hold either inline data (lane 1) or `BufRef` descriptors (lane 2).

```
producer: write descriptors ──▶ ringSubmit(ring)          ← ONE kernel call per batch
kernel:   for each new BufRef: check the producer owns it, flip ownership
          to the consumer, then post a wake message to the consumer's mailbox
consumer: actor wakes (mailbox) → pop descriptors → map-free access
          (already granted) → process → submits releases on the reverse ring
```

- **Per-batch cost:** one `ringSubmit`, n descriptor validations and
  ownership flips, and one mailbox wake. A 4-slot audio batch or a full
  frame of damage both cost one kernel call.
- **Enforcement point:** a submitted buffer leaves the producer immediately.
  It is unmapped on the producer's CPU, so only a local `invlpg` is needed
  and there's no SMP TLB shootdown. The consumer gains access at its next
  switch-in.
- **Wakeup:** the wake is an ordinary actor mailbox message (`ipc/mailbox`),
  so CPS servers `await` buffers like any other message. With Phase E
  (block-on-mailbox) idle consumers sleep instead of polling.
- **Malice:** the consumer library validates every `BufRef` (handle exists,
  `offset + len ≤ size`) before use, and ring indices are masked. A bad
  descriptor fails only its sender's request.

## 6. Who pays — budgets follow ownership (no ambient authority)

- Every task holds a **memory budget capability** (its quota).
  `bufCreate` draws from it, so there's no ambient allocation.
- **Moving a buffer moves its charge** (Genode-style donation). A server
  that receives buffers isn't charged for its clients' data.
- **Requester-provided buffers** are the default (io_uring "provided
  buffers"): for a read, the app **lends** an empty writable buffer and
  `fs_server` fills it and returns it. Servers never allocate on a client's
  behalf, so a client can't make a server run out of memory. Servers that
  must allocate (e.g. a decoded image) do so within the session budget the
  dispatcher granted.

## 7. WASM apps (the default)

Handles are opaque `i32`s in the module; the host owns the translation.
- **v1, one copy at the sandbox edge:** `buf_read(h, off, dst, len)` and
  `buf_write(…)` copy between a buffer and linear memory. This is safe by
  construction and still one copy fewer than message-chunking.
- **v2, zero copy:** an *aperture* reserved at the top of the module's
  linear memory. The host maps a buffer's pages there for the duration of a
  lend or ownership, and unmaps them on transfer. This requires linear
  memory to be region-backed (the open seam already noted for WASM).

The same `ui/`/`fs` client APIs sit on top, so apps don't change between v1
and v2.

## 8. One API, three kernel models, each paying only for its isolation

| | SASOS (ring 0, type-safe) | monolithic (servers are kmods) | microkernel (servers ring 3) |
|-|---------------------------|-------------------------------|------------------------------|
| move | a Nim move of a non-copyable `Buf` (`sink`); **zero runtime cost** | kernel-side server: ownership-table update only | ownership flip + PDE rights at switch |
| lend | scoped borrow (`lent`/`var` parameter) checked at compile time | same as move, auto-return on reply | flip there and back |
| sealed | `Frozen[T]`, no mutators | RO by convention + type | PDE without RW |
| violation | doesn't compile | kernel bug | fault → that task dies |

The ownership state machine and handle tables are one shared, host-tested
module. Only the *enforcement hook* differs per model (an oskit seam).

## 9. Granularity and staging

- **Stage A (now):** a buffer arena of 2 MB blocks mapped with huge pages,
  separate from the 16 app regions. Rights are flipped per block at
  `ringSubmit` and at context switch. Medium objects (4 KB–2 MB) go in a
  session's *pool buffer*, sub-allocated by descriptor. Ownership there is
  enforced per block, and per descriptor by the validated library.
- **Stage B (VISION Q6, signal arrived):** per-task CR3 and 4 KB pages, so
  every descriptor's pages are enforced exactly and a switch is a CR3 load.
  SASOS keeps the shared space; it never needed it.

## 10. Decisions

1. **Adopt the rule** (owned/sealed, move/lend, rings as the only shared
   memory) **with the two size lanes.** I'd pick yes.
2. **Dispatcher-brokered sessions:** control and session setup go through
   the dispatcher; steady-state streams use direct session rings under
   dispatcher policy. I'd pick yes. This is a precise reading of the axiom
   *"all app I/O routes through dispatcher"*, so it is yours to confirm.
3. **Budgets follow ownership; requester-provided buffers by default.**
   I'd pick yes.
4. **Enforcement staging:** Stage A (2 MB blocks, batched flips) now, then
   Stage B (per-app CR3) as the next kernel milestone. I'd pick yes.
5. **Per-task handle tables** carried in messages' `handles[]`, replacing
   global tokens. This is an ABI change for `grantRegion`, `capSend` and
   fs replies. I'd pick yes.
6. **WASM:** a copy at the edge in v1, a region-backed aperture in v2.
   I'd pick yes.
7. **Arena size:** 128 MB in 2 MB blocks for Stage A. I'd pick yes; it's
   tunable.

## 11. Done means (tests)

- **Host:** property test of the ownership state machine (random op
  sequences across tasks; never two accessors of an owned buffer, never an
  early free or a leak); ring stress tests under ASan/TSan; descriptor
  fuzzing (bad `BufRef`s are rejected, never dereferenced).
- **QEMU:**
  - use-after-move faults and kills only that task;
  - writing a sealed buffer faults;
  - a 1 MB `cat` arrives via a lent buffer (checksum);
  - surface handoff at load is pixel-exact;
  - a batch of N transfers costs exactly one `ringSubmit` (counter in `stats`).

Once agreed: freeze §2–§6 and §8 into ARCHITECTURE.md and SPAWN
`subprojects/buffers`. Its first task is a SURVEY of Zircon VMO/handles,
Genode dataspaces, packet streams and quota donation, the Singularity
exchange heap, seL4 frames, and io_uring provided buffers.
