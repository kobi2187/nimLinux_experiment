# Backlog — buffers

Tags: CLEAR / FUZZY / OPEN / PARENT / SPAWN

| # | Tag | Task | Done-check |
|---|-----|------|-----------|
| B1 | DONE | **SURVEY**: Zircon VMOs + handles (rights, transfer in channels), Genode dataspaces + packet streams + quota donation, the Singularity exchange heap, seL4 frame caps, io_uring provided buffers / registered rings; adopt / adapt / build per piece | DECISIONS.md records what was examined, the choice, and the reasons |
| B2 | DONE | `state`: ownership state machine + per-task handle tables + budgets (pure Nim, host) | property test: random move/lend/return/seal/close/exit sequences across tasks never yield two accessors of an owned buffer, an early free, or a leak |
| B3 | DONE | `arena`: Stage A 2 MB block allocator charging budgets | host tests: exhaustion, budget refusal, release at last reference |
| B4 | DONE | `ring`: session ring (staged pushes, `ringSubmit` validates every `BufRef`, flips ownership, one mailbox wake) | host stress test under ASan/TSan; fuzzed bad descriptors are rejected, never dereferenced |
| B5 | FUZZY | `enforce/micro`: PDE rights per block at submit + context switch | QEMU: use-after-move faults and kills only that task |
| B6 | CLEAR | `enforce/sasos`: owned `Buf` type (`=copy` error, `sink` move, scoped lend) | a compile-fail test proves a copy/alias does not compile |
| B7 | CLEAR | `enforce/mono`: ownership-table enforcement for kernel-side servers | monolithic model passes the same QEMU tests |
| B8 | CLEAR | `abi`: ABI vtable entries + WASM host calls (`buf_read/buf_write`) | WASM host test (wasmtime) moves 1 MB with a matching checksum |
| B9 | PARENT | dispatcher forwards handles in `tmTransit` (parent repo) | dispatcher test: a forwarded handle is never mappable by the dispatcher |
| B10 | PARENT | fs_server reads into a requester-provided lent buffer; `cat` reads > 508 B | QEMU: `cat` of a 1 MB file, checksum matches |
| B11 | PARENT | retire global region tokens (`grantRegion`, `memregion`, fs_logic) in favour of handles | no remaining callers; ABI updated in both projects |
| B12 | CLEAR | `stats` counter: kernel calls per `ringSubmit` batch | QEMU: a batch of N transfers = 1 call |
