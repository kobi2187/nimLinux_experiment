# DECISIONS — buffers (append-only)

## 2026-10-27 — Spawned with a frozen API
The parent froze `ipc/buffers.nim` after the human agreed to all seven
decisions of the bulk-data proposal v2 (owned/sealed + move/lend, two size
lanes, dispatcher-brokered sessions, budgets follow ownership, Stage A → B
enforcement, per-task handle tables, WASM edge copy, 128 MB arena of 2 MB
blocks). The why and the rejected alternatives: parent DECISIONS.md
§Bulk data FROZEN and docs/proposals/bulk_data.md.
