# Bulk data: buffers, handles, rings — proposal (NOT frozen)

Status: **PROPOSED 2026-10-27**. The human's requirement: one general,
explicit, formal mechanism for big data — no copying through messages, but
also no "unsafe shared memory". Decisions needed are in §8.

## 1. What we have today (tested 2026-10-27)

Region capabilities exist (`capMemRead/Write/Grant`, `capGrantRegion`,
refcounts, `tests/test_zerocopy.nim`), and `fs_server`'s logic hands a read
cap to the caller. A probe found it unsafe:

| # | Hole | Status |
|---|------|--------|
| 1 | any task could mint a **write** cap on any region by slot number | **fixed**: only the owner or a `capMemGrant` holder may mint |
| 2 | owner exit freed the slot **while caps still named it**; the next app got that memory (use-after-free across apps) | **fixed**: owner holds a reference; the slot is recycled at the last reference |
| 3 | freed handles still reported valid; exiting tasks leaked their caps | **fixed** (`regionValid` = allocated; exit revokes all caps) |
| 4 | rights are advisory: the app gets a raw pointer, and every app region is user-accessible to every task | **open**: needs enforcement (§5) |
| 5 | tokens are global and guessable (serial + slot); a message can't carry a cap to another task | **open**: per-task handle tables (§3) |

## 2. The rule

> **Mutable memory is never shared.** At any instant a buffer is either
> **owned** (exactly one task may access it), or **sealed** (immutable,
> any number of readers, including the former owner).
> The only concurrent shared memory is the kernel-provided **ring**, whose
> layout and protocol are implemented once, in one audited module.

This is Rust's *aliasing XOR mutability* enforced at the OS level: by the MMU
in the ring-3 models, and by the type system in SASOS.

## 3. Objects and handles

- **Buffer**: a kernel object owning memory (size, state: `owned | lent | sealed`).
- **Handle**: a per-task index into that task's handle table, like an fd.
  Handles are never global numbers, can't be guessed, and confer exactly
  their rights (`read`, `write`, `map`, `transfer`). This replaces passing
  region slot numbers and global `CapToken`s.
- **Ring**: a kernel object with two *ends* (producer, consumer), each a
  handle. Fixed-size slots, single producer / single consumer.

## 4. Operations (the whole API)

| op | effect | invariant kept |
|----|--------|----------------|
| `bufCreate(size) → h` | new owned buffer | I1 |
| `bufMap(h) → ptr` / `bufUnmap(h)` | access in the caller's view, with the handle's rights | I1, I2 |
| `send(chan, msg, [h…], mode)` | handles travel *with* the message; the kernel translates them into the receiver's table | I4 |
| mode **move** | the sender's handle is gone (unmapped); the receiver owns the buffer | I1 |
| mode **lend** | the receiver gets access until it replies or calls `bufReturn`; the sender has no access meanwhile | I1 |
| mode **share** | only for sealed buffers: the receiver gets read access | I2 |
| `bufSeal(h)` | owned → sealed, forever read-only for everyone | I2 |
| `bufClose(h)` | drop the handle; memory goes at the last reference | I3 |
| `ringCreate(slots, slotSize) → (prod, cons)` | the ends are transferable like any handle | I6 |

Bulk transfer is always: data in a buffer, plus a small message or ring
descriptor `{handle, offset, len}`. The receiver bounds-checks the
descriptor before use (I5).

Examples:
- **File read** (`fs_server` → app): read into a new buffer, **move** it in
  the reply. A big file costs zero copies, and there's no 508-byte limit.
- **File write** (app → `fs_server`): **lend** the buffer read-only; it
  comes back on reply.
- **Font / asset cache** shared by many apps: **seal**, then **share**.
- **Surface** (app_server): a swapchain of N buffers. On commit the app
  **moves** a buffer to the server; on release the server moves it back.
  The two sides never touch the same pixels at the same time, and that is
  enforced, not promised.
- **Input events, packet descriptors, audio periods:** a **ring**.

## 5. Invariants and how each is enforced

| | invariant | ring 3 (mono / micro) | SASOS (ring 0, type-safe) | WASM apps |
|-|-----------|-----------------------|---------------------------|-----------|
| I1 | an owned buffer is accessible by exactly one task | page permissions follow ownership on every context switch (§6) | `Buf` is a non-copyable owned type (`=copy` is an error); `sink` moves; `lend` is a scoped borrow | handles are opaque; data is reached via host calls or a mapping into linear memory that the host revokes |
| I2 | sealed means read-only for all | mapped without the RW bit | `Frozen[T]` exposes no mutators | read-only host view |
| I3 | memory lives while any handle or in-flight message refers to it | refcount in the kernel object | ARC `=destroy` | same kernel object |
| I4 | authority only by creation or receipt | per-task handle table; messages carry indices that the kernel translates | handles are values; no forging without `cast` (banned in apps by lint) | host table per module |
| I5 | descriptors are bounds-checked | in the receiving library | same library | host |
| I6 | rings are the only concurrent sharing | one module (`ipc/ring`), stress- and model-tested | same | host-side ring |

Violations become **faults on the offending task**, killing it (built last
session), never corruption of another task.

## 6. Enforcement mechanics for ring 3, staged

- **Stage A (now, shared address space):** buffers are 2 MB-granular blocks
  in a buffer arena mapped with huge pages. On a context switch the kernel
  sets User/RW on the PDEs of buffers the incoming task holds, and clears
  them for the outgoing task's buffers. That costs a few PDE writes plus
  `invlpg` per switch, and gives real I1/I2 enforcement without per-app
  page tables.
- **Stage B (VISION open question 6):** per-task CR3. Mappings live in each
  task's tables, a switch is a CR3 load, and granularity drops to 4 KB pages.
  This proposal is the *resolving signal* for Q6: app_server is the first
  service that must be protected from its clients.

## 7. Tests that define "done"

- **Host:** a state-machine test of move / lend / return / seal / close
  across tasks (property-based: random op sequences must never let two tasks
  hold access to an owned buffer, and must never leak or free early); ring
  SPSC stress tests under threads (ASan + TSan).
- **QEMU** (`make test-devices`):
  - touching a buffer after moving it faults, and only that task dies;
  - writing a sealed buffer faults;
  - a 1 MB file arrives in `cat` by move, verified by checksum;
  - surface handoff under load gives a pixel-exact screendump.

## 8. Decisions

1. **Adopt the rule and the four modes** (owned / move / lend / sealed
   share, plus typed rings). I'd pick yes.
2. **Ring-3 enforcement:** I'd pick *Stage A now* (per-switch PDE rights in
   a buffer arena; small, unblocks app_server) and *Stage B* (per-app CR3)
   as the next kernel milestone.
3. **Handles:** I'd pick per-task handle tables, with capabilities carried
   in messages and translated by the kernel. This replaces global tokens,
   so it is an ABI change for `grantRegion`, `capSend` and `fs_server`.
4. **Buffer arena size:** I'd pick 128 MB in 2 MB blocks in Stage A (a
   1280×800 surface is 2 blocks), separate from the 16 app regions.

Once agreed: freeze §3–§5 into ARCHITECTURE.md and SPAWN `subprojects/buffers`.
Its first task is a SURVEY (Zircon VMO/handles, Genode dataspaces and packet
streams, Singularity exchange heap, seL4 frames, io_uring rings). The
app_server proposal then uses buffers for surfaces and rings for events
instead of an ad-hoc shared region.
