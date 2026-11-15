# HANDOFF.md — Session Exit Note

Last updated: 2026-11-15. (Rewritten each session; older notes are in git history.)

S8b (buffers owned per 4 KB page), the retirement of session rings, and S3a (spawn authority: a process
handle, a launcher module, manifests intersected with a system policy) are merged to `master` via PR #11;
AGENTS.md was revised with the human (backup in `docs/archive/`). Next: K1 (contract/IDL) as a proposal
first, then K3 device ports so S3b can remove the ambient chanSend / event topics / first-present display.
Open decisions are in STATE.md "Awaiting human". Watch the low-memory budget: the kernel image ends near
29 MB and app regions start at 32 MB.
