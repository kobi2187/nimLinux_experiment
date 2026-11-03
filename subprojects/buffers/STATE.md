# STATE — buffers

Last updated: 2026-10-27

- B1 SURVEY done: adapt Zircon (handles), Genode (sessions, quota), Singularity (SASOS linear ownership), seL4 (lend = derived handle), io_uring (batches, provided buffers); build the code.
- B2 done: `ipc/buffers/state.nim` + `tests/test_buffers_state.nim` (13 tests incl. a 45k-step property test; mutation-validated oracle).
- Facade `ipc/buffers.nim` is still the stub (by design until enforcement exists: nothing may rely on unenforced semantics).
- B3 done: `ipc/buffers/arena.nim` (whole-block runs, one-word free map) wired into the store; buffers are charged the blocks they occupy; `bufMapAddr` gives an address only while access holds.
- B4 done: `ipc/buffers/ring.nim` — staged pushes, one `ringSubmit` per batch (validate, flip ownership, one wake), attached handle set, `ipc/mpsc_ring` queue.
- B5 done: Stage A enforcement live (`kernel/buffers/kbuffers.nim`, per-switch PD rights over the arena); ELF ABI syscalls 30–36; QEMU `buftest` proves use-after-move / sealed-write / write-while-lent fault and kill only that task.
- Next: B6 SASOS type-level `Buf`, B7 monolithic, ring syscalls + WASM host calls (B8), then B10 fs_server with lent buffers.
