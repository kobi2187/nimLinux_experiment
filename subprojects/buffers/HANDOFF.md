# HANDOFF — buffers

B1 and B2 are done. The state machine (`ipc/buffers/state.nim`) is the heart
of the module, and its oracle, `checkInvariants`, is the contract the other
layers must preserve: call it in tests after every operation. Next is B3
(the arena: 2 MB blocks in a 128 MB window, allocated at `bufCreate`,
released at the last reference), then B4 (rings). Do not change
`ipc/buffers.nim` / `types.nim` without a dialogue with the human; it is
logged in both projects.
