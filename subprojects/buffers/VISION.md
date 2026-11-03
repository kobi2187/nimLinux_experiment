# Vision — buffers (sub-project of NimixOS)

Implement the frozen bulk-data API **`ipc/buffers.nim`**, well. Spec:
`docs/proposals/bulk_data.md` (v2, FROZEN 2026-10-27). Big data moves
between tasks with zero copies and **no mutable shared memory**: a buffer is
owned by exactly one task or sealed (immutable); it changes hands only by
move or lend; rings carry only descriptors and ≤240-byte inline payloads.

Done enough when every done-check in §11 of the spec passes on all three
kernel models, and the parent's region-token users (fs_server, memregion)
have migrated to handles.

## Goals (observable, ranked)
G1. **The rule holds, provably:** a host property test (random op sequences
    across tasks) never finds two accessors of an owned buffer, an early
    free, or a leak.
G2. **Violations are faults, not corruption:** in the microkernel and
    monolithic models a use-after-move or a write to a sealed buffer kills
    only the offending task (QEMU test); in SASOS it does not compile.
G3. **Performance by design:** a batch of N transfers costs exactly one
    kernel call (`ringSubmit`); ≤240 B never allocates a handle; the
    dispatcher forwards handles without touching data.
G4. **No ambient authority:** every buffer is charged to a budget, charges
    follow ownership, and handles are per-task table indices.
G5. **WASM apps use it:** v1 copies at the sandbox edge (`buf_read/buf_write`).

## Non-goals (v1)
- Per-app CR3 (that is Stage B, a parent kernel milestone; Stage A uses
  per-switch page rights on 2 MB blocks).
- WASM zero-copy aperture (v2, needs region-backed linear memory).
- SMP TLB shootdown (single CPU; a move unmaps on the sender's own CPU).

## Taste / preferences
- Mechanism in the kernel, policy in servers (the dispatcher decides sessions).
- One shared, host-tested state machine; per-model code only in `BufEnforcer`.
- Reuse `ipc/mpsc_ring` and `ipc/mailbox` before building anything new.
- `--os:any`, no allocation in the kernel paths, procs small, invariants asserted.
- The API in `ipc/buffers.nim` is the definition of done. Changing it is
  cross-cutting in BOTH projects: dialogue with the human, log in both DECISIONS.md.

## Open questions (parked)
- Q: Stage A rights flip — at `ringSubmit` only, or also lazily at switch-in?
  Resolving signal: the B5 enforcement prototype's switch-path cost under `make test-devices`.
- Q: How does a borrower's crash end a lend (auto-return vs. buffer lost)?
  Resolving signal: the state-machine property test (B2) forces a choice.
