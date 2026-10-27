# STATE — buffers

Last updated: 2026-10-27

- B1 SURVEY done: adapt Zircon (handles), Genode (sessions, quota), Singularity (SASOS linear ownership), seL4 (lend = derived handle), io_uring (batches, provided buffers); build the code.
- B2 done: `ipc/buffers/state.nim` + `tests/test_buffers_state.nim` (13 tests incl. a 45k-step property test; mutation-validated oracle).
- Facade `ipc/buffers.nim` is still the stub (by design until enforcement exists: nothing may rely on unenforced semantics).
- B3 done: `ipc/buffers/arena.nim` (whole-block runs, one-word free map) wired into the store; buffers are charged the blocks they occupy; `bufMapAddr` gives an address only while access holds.
- B4 done: `ipc/buffers/ring.nim` — staged pushes, one `ringSubmit` per batch (validate, flip ownership, one wake), attached handle set, `ipc/mpsc_ring` queue.
- Next: wire the facade `ipc/buffers.nim` into the kernel (pid → TaskId map, arena window mapping, ABI entries) = B8 groundwork, then enforcement (B5 micro, B6 SASOS, B7 mono).
