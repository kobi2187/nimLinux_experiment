# HANDOFF.md — Session Exit Note

Last updated: 2026-11-17. (Rewritten each session; older notes are in git history.)

Result (b) is delivered: the keyboard/mouse path is a typed device port (`ipc/ports`, `kernel/ports`), held by one
program at a time through a handle the launcher moves from the console on `grant input`; the global `input` topic and
the PS/2 topics are gone; `keyboard-isolation` shows a keylogger sees nothing. Also this session: result (a) (the
39-test device suite passes on all three kernels), a static-checking audit, K3 layer 1, AGENTS.md revised (STEP BACK,
VERIFY, question template, engineering principles). Next, by the picture in STATE.md: the display port the same way
(M1, replaces first-present display), PS/2 routed into the input port (R3b), then the questions that need you
(K1 contract/IDL; E1 event server; users). Watch the low-memory budget (kernel image ends near 29 MB; regions start at 32 MB).
