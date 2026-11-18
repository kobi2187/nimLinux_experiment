# Architecture — buffers (living map)

## Frozen boundary (parent)
`ipc/buffers.nim`: types `BufHandle, BufRights, BufState, TransferMode,
BufError, BufRef(12 B), MsgHandle, RingSlot(256 B), RingEnd, BufEnforcer`;
procs `bufCreate/Map/Unmap/Size/State/Seal/Return/Close`, `msgSend/msgRecv`,
`bufRefCheck`, `ringCreate/Push/Submit/Pop`, `budgetAvailable`,
`installEnforcer`. Layouts pinned by the parent's `tests/test_buffers_api.nim`.
Today it is a stub returning `beNotImplemented`.

## Module tree (proposed starting map — this orchestrator may redraw it)
- `state`    [BUILT `ipc/buffers/state.nim`] pure ownership state machine: buffers, per-task handle
  tables, lends, seals, refcounts, budgets. Host-testable; the heart.
- `arena`    [BUILT `ipc/buffers/arena.nim`] Stage A: 128 MB arena of 2 MB blocks (allocation, budget charge).
- `ring`     [BUILT `ipc/buffers/ring.nim`] session rings over `ipc/mpsc_ring` semantics; staging,
  `ringSubmit` validation, mailbox wake.
- `enforce/` [PLANNED] `BufEnforcer` per model: `sasos` (no-op + owned `Buf`
  type with `=copy` error), `mono` (table), `micro` (PDE rights per block at
  submit/switch).
- `abi`      [PLANNED] ABI vtable entries + WASM host calls (`buf_*`, `ring_*`).

## Assembly plan
- `ipc/buffers.nim` (parent) delegates to `state` + `arena` + `ring`; the kernel
  models call `installEnforcer` at boot.
- The dispatcher forwards handles with `tmTransit` (parent work, B9).
- fs_server switches to requester-provided buffers (`tmLend`) (parent work, B10).
- app_server (parent, next spawn) uses session rings + swapchain moves.

## Seams under tension
- `BufEnforcer` granularity: 2 MB blocks now, 4 KB pages after Stage B (per-app CR3).
- Handle tables vs. the legacy global `CapToken`: they coexist until the migration (B11).

## Spawned sub-projects
- none

## Drift log
- 2026-10-27: the frozen types moved to `ipc/buffers/types.nim` (re-exported by `ipc/buffers.nim`; API unchanged) so implementation modules share them without a cycle.
- 2026-10-27: spawned from the parent with the frozen API → parent DECISIONS §Bulk data FROZEN.
