# DECISIONS — buffers (append-only)

## 2026-10-27 — Spawned with a frozen API
The parent froze `ipc/buffers.nim` after the human agreed to all seven
decisions of the bulk-data proposal v2 (owned/sealed + move/lend, two size
lanes, dispatcher-brokered sessions, budgets follow ownership, Stage A → B
enforcement, per-task handle tables, WASM edge copy, 128 MB arena of 2 MB
blocks). The why and the rejected alternatives: parent DECISIONS.md
§Bulk data FROZEN and docs/proposals/bulk_data.md.

## 2026-10-27 — B1 SURVEY: adapt designs, build the code

There is no library to *adopt*. Every candidate is an OS mechanism, not a
library, and none is freestanding Nim. Each design was examined for the piece
of our frozen API it fits best:

| prior art | what it does | what we take | what we leave |
|-----------|--------------|--------------|---------------|
| **Zircon** (Fuchsia) VMOs + handles | per-process handle tables; rights (READ/WRITE/MAP/TRANSFER/DUPLICATE); `zx_channel_write` *consumes* the sender's handles, even on failure | **adapt**: per-task tables; rights as a set; handles leave the sender at send time (no "half-sent" state); generation bits in handle values against stale reuse | VMO clones/COW, a pager — far beyond v1 |
| **Genode** dataspaces + packet streams + quota | bulk dataspace + submit/ack queues; the client *donates* RAM quota to the server at session creation | **adapt**: session rings with a submit queue and a reverse release queue; budgets that move with ownership and session donation | shared dataspaces both sides map: exactly the mutable sharing our rule forbids |
| **Singularity** exchange heap | blocks in a shared heap with exactly one owner; channels transfer ownership; enforced statically by linear types (Sing#) | **adapt for SASOS**: an owned non-copyable `Buf` (`=copy` error, `sink` moves, scoped lends) gives the same guarantee via Nim's type system at zero runtime cost | a GC'd shared heap — we use the arena |
| **seL4** frame caps + capability derivation tree | authority to map is a cap; revoke reaches every derived cap | **adapt**: lends are derived handles; ending a lend (return/exit) revokes the borrower's handle and every forward of it | full CDT generality — one level (lend) suffices |
| **io_uring** SQ/CQ rings, provided buffers | one `io_uring_enter` submits a batch; the app provides read buffers up front | **adapt**: one `ringSubmit` per batch; requester-provided buffers as the default for reads | kernel-polled SQ (SQPOLL) — single CPU, no spare core |

Build: the state machine (pure Nim, fixed tables, `--os:any`), arena, ring
on `ipc/mpsc_ring` semantics, per-model enforcement. The rejected
alternative, "port one of these", fails on dependencies and kernel coupling
in every case.

Parked question resolved for B2: **a borrower that exits auto-returns the lend**
(the seL4-style revoke of a derived handle). The lender regains sole
ownership; the contents are whatever the borrower left. A lender that
closes or exits mid-lend relinquishes the buffer, which is freed on return.

## 2026-10-27 — B2: the ownership state machine (`ipc/buffers/state.nim`)

Fixed tables (64 buffers, 32 tasks × 32 handles, 64 in-flight transfers), no
allocation, compiles for `--os:any`. Handles are `(generation << 16) | slot+1`
per task, so stale or foreign values are rejected. Transfers are two-phase:
`bufSend` (the handle leaves the sender now, as in Zircon; the flight holds
the reference) → `bufDeliver` (as owner, borrower, reader, or `asTransit`
for the dispatcher) or `bufCancel` (a move is lost, a lend returns, a share
releases). Budgets: create charges; a move's delivery re-charges the
receiver (refused on no budget, retryable); exit orphans the charges of
buffers others still hold.

The oracle `checkInvariants` covers:
- I1: ≤1 accessor of an owned buffer;
- I2: sealed means no writer and no write right;
- I3: refcount = handles + flights, no dangling reference, no leak;
- owner field = holder of the owner handle (enforcement reads it);
- exactly one lend holder per lent buffer;
- charges add up, and no task exceeds its budget.

**Validated by mutation testing:** 12 hand-made mutants against 13 tests,
including a 300-seed × 150-step random property test with garbage handles.
Every behavioural mutant is killed. Equivalent mutants led to two invariants
being added (owner field, sealed rights) and two redundant pieces of code
being deleted: a double borrower-move guard, and the `lenderGone` flag,
which refcounting already covers. One survivor was a real liveness gap: a
transit holder closing a lend left the lender locked out. It is now caught
by the lend-holder invariant.

## 2026-10-27 — B3: arena of whole blocks (`ipc/buffers/arena.nim`)

A window of ≤64 equal blocks (Stage A: 64 × 2 MB). The free map is one
`uint64`, and allocation is first fit over contiguous runs. A buffer always
takes whole blocks: the block is the enforcement unit, so two owners never
share one. **A buffer is charged the blocks it occupies**, not the bytes it
asked for (honest accounting: that memory is unavailable to others). The
cost is that small buffers waste up to a block; the inline lane (≤240 B) and
the per-session pool buffer exist for exactly that, and Stage B's 4 KB pages
remove it. The store owns the arena (`initStore(base, granule, blocks)`;
tests use 1 KB granules). The invariants gained: no two live buffers share a
block, and allocated blocks = the live buffers' runs. Mutants A1 (blocks
never freed) and A2 (charging bytes instead of blocks) are killed.

## 2026-10-27 — B4: session rings (`ipc/buffers/ring.nim`)

The producer stages slots with `ringPush` (no kernel call). `ringSubmit` is
the one kernel call per batch. For each staged `BufRef` it:
1. resolves `handleIdx` in **the producer's own** handle table (`handleAt`),
   so a descriptor can never name another task's buffer;
2. bounds-checks `offset + len` against the buffer;
3. moves the buffer (or shares it, if sealed: flag bit 0) to the consumer;
4. files the consumer's new handle in the ring's attached set and rewrites
   `handleIdx` to that index (the spec's "ring's attached set").

A failed delivery (e.g. the consumer is out of budget) cancels the flight,
so the buffer is lost rather than duplicated. A bad slot is rejected alone.
Accepted slots go on an `ipc/mpsc_ring` queue (reused, not rebuilt), and a
non-empty batch counts **one** wake (`ringStats`). The consumer pops slots
and claims handles with `ringTake`. Ring ends encode
`(ringIndex << 1) | isConsumer`, and only the tasks the session named may use
them. Tests: 7, including a 200-round random-batch test against the state
invariants. Mutants R1–R5 are all killed: no bounds check, leaked flight,
a wake per slot, a descriptor resolved in a foreign table, an oversized
inline slot.

## 2026-11-03 — Stage A enforcement live (B5) + ELF ABI (B8, part)

`kernel/buffers/kbuffers.nim` holds the global store over the arena window
and applies `blockAccess(task)` to the arena PD entries at every switch and
after every buffer syscall (diffed, with `invlpg` per changed block). Task
identity is the process-table slot; a task attaches on its first buffer call
and is detached by task cleanup. The ELF ABI is syscalls 30–36. Message
handles use `BufMsgHandles` (count + 4 handles + 4 modes), because the
syscall gate has 4 argument registers. `tmTransit` cannot be sent from
userspace. QEMU-verified with `buftest` (ok, pass, and faults on move, seal
and lend). Still open: SASOS (B6) and monolithic kernel-side (B7)
enforcement, ring syscalls, WASM host calls (B8 rest), and the
`ipc/buffers.nim` facade, which stays a stub for in-kernel callers until B6/B7.
