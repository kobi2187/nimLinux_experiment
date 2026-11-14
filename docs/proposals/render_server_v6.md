# V6: the render server — decomposition, decisions and consequences (PROPOSED, nothing frozen)

Status: **PROPOSED 2026-11-13**, for the human to converge on before the V6 sub-project is spawned
(AGENTS.md §SPAWN: the seam is drawn with the human, then frozen). Written on request:
"tell me which decisions are needed, and all their repercussions and consequences."

Builds on, and does not reopen: `render_server.md` (AGREED: raylib once, natively, as the server; apps
describe, server owns pixels; one server with two faces), `draw_protocol.md` (AGREED in principle: flat
binary records, app-chosen ids, the bridge), `bulk_data.md` (frozen buffers rule), `app_server_api.md`
(AGREED: window manager roles), VISION §Rendering model and budgets.

## 0. Summary for a reader in a hurry

- V6 is **not one task**. Today there is no way for a program to ask anything of a server except
  through named channels (256-byte messages, 16 deep, 4 buffer handles each); no blocking wait (every
  server polls on a 10 ms tick); no client of the server exists yet (RUI runs in-process; WASM apps
  need V8); the shell and console cannot be shown through a server (the console is a kernel task).
  The render server touches all of that.
- It is **seven independently valuable slices** (§6), each ending in a visible, tested result, each
  a small PR. The first (V6a) needs only two of the decisions below.
- **Twelve decisions** (§3). Five are real boundary calls that need you (D1 transport, D3 who may own
  the display, D4 who may read input, D5 what the user sees when the server runs, D7 how sessions are
  brokered). The rest I would decide myself and log, because they stay inside one module.
- **Measured today** (§2): on NimixOS under QEMU TCG a 640x400 frame costs 142 ms to rasterize and
  8.5 ms to read back and present; at 1280x800, 557 ms and 20.7 ms. Rasterization is 94-96 % of the
  frame. This sets which costs matter (damage limiting, yes; extra copies, much less) and means
  **frame-rate budgets cannot be gated under TCG**, only counts can.
- **The biggest hidden consequence**: every buffer costs at least one 2 MB arena block, and the arena
  is 64 blocks. A command buffer per frame per client, and a surface per window, burn the arena
  quickly. The transport and surface decisions (D1, D8) and the sizing decision (D10) are one problem.

## 1. Where the boundary goes (the seam to freeze)

The sub-project `subprojects/render_server` would be treated as a black box behind **three frozen
interfaces**; everything else inside it stays reversible.

```
                     kernel (mechanism)                                 render_server (sub-project)
 client (ELF/WASM)   ┌──────────────────────────────┐                  ┌───────────────────────────────┐
 ─ control msgs ───▶ │ named channel "render"       │ ──▶ I2 ───────▶ │ session   (hello, window ctl) │
 ─ frames/surfaces ─▶│ buffers: move/lend/seal      │                  │ protocol  (decode, validate)  │
 ◀─ events ───────── │ event delivery               │ ◀── I2 ───────  │ executor  (raylib/rlsw)       │
                     │                              │                  │ compositor(z-order, damage)   │
 input hw ─────────▶ │ "input" topic     ───────────┼──▶ I3 ────────▶ │ wm        (focus, routing)    │
                     │ display ABI v1/v2 ◀──────────┼─── I1 ◀───────  │ present   (blit, flush)       │
                     └──────────────────────────────┘                  └───────────────────────────────┘
```

| interface | what crosses | state today |
|-----------|--------------|-------------|
| **I1 kernel to server: display** | `nimixDisplayInfo/Present/Modes/SetMode`, ownership, release on exit | BUILT (v1+v2). Needs D3 (who may own). |
| **I2 client to server: protocol** | control messages (hello, createWindow, resize, close, ...), draw records, surface commits, event records | records exist in `bridge/rl_protocol.nim` (P0, 45 routed ops); control and event records unwritten; transport undecided (D1) |
| **I3 kernel to server: input** | evdev triples on the `input` topic; later a capability and focus | BUILT but unrestricted (any task may subscribe). Needs D4. |

Inside the sub-project (free to change, one module each, host-tested where pure):
`protocol` (records, validation: pure), `executor` (records into raylib targets), `compositor`
(window stack, occlusion, damage rectangles: pure), `wm` (focus, decorations, input routing policy:
pure), `session` (brokering, budgets), `present`.

## 2. What exists and what it costs (facts, so decisions are not argued from memory)

| fact | value | consequence for V6 |
|------|-------|--------------------|
| channel message | 256 bytes, queue 16 deep, 4 buffer handles per message | a steady frame is 19 records / 424 B (P0): does not fit one message |
| a buffer | at least one 2 MB block; arena 128 MB = 64 blocks; per-task budget 32 MB = 16 blocks | a per-frame command buffer = 2 MB; double-buffered per client = 4 MB; a 1280x800 surface = 2 blocks |
| blocking | none: servers poll; `nimixSleep` granularity is the 10 ms PIT tick | every hop costs up to 10 ms; key-to-pixel budget is 33 ms p95 |
| rings | host module done (B4); no kernel syscalls (`ringCreate/Push/Submit/Take` unwritten) | the "1 ringSubmit per frame" budget cannot be met yet |
| input topic | any task can subscribe and read every key | with a server, this is a keylogger for every app |
| display ownership | implicit: first present wins | any app can race the server to the screen |
| console and shell | the shell is a kernel task; the console owns the display until a program takes it | when the server owns the display, the shell has no screen |
| raylib client | `PLATFORM_NIMIX` presents straight to the display | C ELF apps (rldemo, rlkeys, rlmouse) would need a mode that talks to the server |
| WASM apps | wasm3 is in the kernel; V8 (userspace host) not built | WASM clients are blocked on V8; the first clients are ELF |
| measured, 640x400, TCG | draw 142 ms, end (readback + present) 8.5 ms per frame | rasterization is 94 % of the frame |
| measured, 1280x800, TCG | draw 557 ms, end 20.7 ms per frame | same ratio at four times the area; rlsw cost scales with pixels touched |
| measured, 320x200, TCG | draw 63 ms, end 3.8 ms per frame | |

(Measured with `apps/c/rlbench`, added with this proposal. A representative widget-like scene, not RUI's.
TCG is an emulator: use the ratios, not the milliseconds. P0's host numbers: about 10 ms for a steady
RUI frame at 640x400, command encoding under 1 microsecond, remote versus direct within noise.)

## 3. The decisions

Legend: **Gate** = needs the human (boundary, public interface, or costly to undo); **Mine** = I
decide and log it (stays inside one module, reversible).

| # | question | gate | my pick | blocks |
|---|----------|------|---------|--------|
| D1 | client transport | **Gate** | channel messages now, behind a `transport` interface; rings and a small-buffer lane next | everything client-side |
| D2 | blocking and wakeup | Gate (kernel work) | poll behind a `wait` abstraction now; real block-on-wake as its own kernel slice | latency budget |
| D3 | who may own the display | **Gate** | an explicit display capability, granted to the server at spawn | V6a security; direct-mode apps |
| D4 | who may read input | **Gate** | restrict the `input` topic by capability; the server routes by focus | V6c |
| D5 | what the user sees when the server runs | **Gate** | opt-in program first; a terminal window is the first real client; boot default later | the whole UX |
| D6 | server implementation language | Mine (after a spike) | Nim core compiled with picolibc + raylib; C as fallback | V6a build |
| D7 | session brokering and the dispatcher | **Settled 2026-11-14** | the dispatcher brokers sessions (the existing design stands); my earlier "direct, temporary exception" pick is withdrawn. Consequence: V6 depends on dispatcher Stage 2 | V6b |
| D8 | window content: server-drawn, client-drawn, or both | Gate (shapes the protocol) | both: commands by default, plus surface commits so every existing raylib ELF app becomes a window | V6d |
| D9 | compositing and damage | Mine | damage-limited from the first compositor | |
| D10 | mode, memory and budgets | Gate (VM size, arena size) | server owns the mode; arena 256 MB, VM 384 MB; server budget class | V6b+ |
| D11 | fairness and failure | Mine (log it) | per-turn work caps; crash returns the console | |
| D12 | protocol freeze and versioning | Gate (frozen API) | freeze what P0 emits, plus hello/feature bits; SDF/backdrop later | V6 spawn |

Each is expanded below. "Consequences" lists what the choice forces elsewhere, including what it makes
harder. "If not" says what the next-best alternative costs.

---

### D1. How do clients talk to the server? (transport)

**The problem.** Draw records are tiny (424 B steady, 2.2 KB full repaint) but do not fit one 256-byte
channel message. A buffer fits any size but costs a 2 MB block. Rings (one submit per batch) are the
agreed end state but have no kernel syscalls yet.

| option | per steady frame | cost today | gives |
|--------|------------------|------------|-------|
| A. chunked channel messages (256 B each) | 2-3 `bufMsgSend` for 424 B | none new; copies; no ownership flips | works now; chatty; a full repaint is 9+ messages and the 16-deep queue fills |
| **B. one buffer per frame, moved by `bufMsgSend` (handles ride the message)** | 1 send + 1 receive of the release | exists; but each frame buffer = one 2 MB block | the agreed ownership model; fastest to build; wasteful in arena |
| C. session rings (`ringSubmit`) | 1 call per batch | needs 4 syscalls, ring tests in QEMU, the B8 slice | the end state; meets the 1-call budget |
| D. a long-lived command buffer sub-allocated in a pool (small-buffer lane) | like C | needs pools (not built) | arena-friendly |

**My pick:** B behind a `transport` interface (`send(frame)`, `recv()`, `release()`), A for control
messages (they are small), then C and D as one kernel slice (V6e) swapped in under the same interface.
The server and clients do not change when the transport does.

**Consequences.**
- Arena cost is real: a client holding two frame buffers holds 4 MB. With 64 blocks in total, the server
  plus about ten clients exhaust the arena (D10 raises it; D1-D is the real cure).
- The budget "about 1 `ringSubmit` per frame" is **not met by B**; B needs about 3 kernel calls per frame
  (send, receive of the release, plus the wake). That is inside the "at most 4 transitions" bound but
  not the "1" target. The CI count gate has to be written against the transport that exists, and
  tightened when C lands.
- Tiny frames (cursor blink, one blit) would still take a whole buffer under B. Under A they fit one
  message. A small-frame fast path (inline, at most 240 B) is cheap to add and covers idle-ish UIs.
- Buffers moved per frame means the client cannot reuse its command buffer until the release arrives:
  two buffers per client (double buffering) is the minimum.
- Choosing B commits the **kernel** to flipping page rights per frame per client (the Stage A
  `applyRights` cost on every context switch grows with the number of live blocks).

**If not B:** A alone is simplest to build and has the worst cost (many calls, queue pressure, no
ownership benefit); C first delays the first visible slice by the whole ring-syscall slice.

---

### D2. Blocking and wakeup: does the server sleep until something happens?

**The problem.** There is no blocking receive. A server loops: poll channels, poll the input topic,
`sleep` one tick (10 ms), repeat. Per hop that is up to 10 ms of latency and a CPU that never idles.

**My pick:** do not block V6a/V6b on it. Write all server loops against one function,
`wait(sources, deadline) -> ready`, implemented as poll + yield + sleep today. Deliver real
block-on-wake as a separate kernel slice (BACKLOG "Phase E"), then swap the function body.

**Consequences.**
- Key-to-pixel latency in V6 is bounded below by about 10-20 ms of polling per hop until the kernel
  slice lands. The 33 ms p95 budget is only gated on KVM, and this environment has no KVM: under TCG
  the budget is tracked, not gated, so the polling start does not fail a gate. It will fail the budget
  on real acceleration, which is the signal to do the kernel slice.
- "Idle: 0 frames, the server presents nothing" is achievable with polling (presenting nothing costs
  nothing) but **CPU use is not zero**; an idle server still wakes 100 times a second. Power is
  irrelevant here; CI timing is not (more wakeups, slower tests under TCG).
- Real blocking needs: a blocked state in the scheduler, wake-on-deliver from IRQ context (input), and a
  sub-tick timer for frame pacing (BACKLOG V2c, `nanosleep` below 10 ms). The timer is a choice of its
  own: raise the PIT rate to 1 kHz (simple, 10x the interrupts under TCG), a one-shot PIT or APIC timer
  (more kernel work, exact), or the TSC deadline (needs APIC). I would take the one-shot PIT first.
- It also unblocks the audio server, the fs_server and every other CPS actor; it is the most reusable
  kernel slice on the list, which argues for doing it early even though V6 does not strictly need it.

**If not (block first):** nothing in V6 happens until a scheduler change lands. I do not recommend it.

---

### D3. Who is allowed to own the display?

**The problem.** Ownership is implicit: whoever presents first owns the screen until it exits. With a
server this is a hole in two directions: any program started before the server owns the screen and the
server gets "busy"; any program started after cannot get in, which is the intended behaviour only if the
server is the owner.

| option | meaning |
|--------|---------|
| A. keep implicit; start the server first | races; a hostile program that starts earlier wins |
| **B. an explicit display capability** minted for the server when it is spawned; `present` and `setMode` check it | one more privilege in the spawn path; direct apps need a handover |
| C. a name claim ("display server") on first come | squatting again |

**My pick:** B. `procSpawnRing3` gains a "rights" word; the shell's `run` command (or a boot config)
spawns the render server with `display` and `input` rights; everything else gets neither.

**Consequences.**
- **ABI change in display v1/v2** (cross-cutting, logged in both places): `nimixDisplayPresent` and
  friends return a new error (-4 "no right") instead of implicitly granting. The existing tests that
  present from a plain app (`gfxtest`, `rldemo`, `rlkeys`, `rlmouse`) would fail unless they are spawned
  with the right. The shell needs a way to give it (`run --display app`), or those apps keep working in
  a "direct mode" in which the right is granted when no server is running. I would keep that fallback:
  the display is free to claim when no render server exists. That keeps every existing test as is.
- **Direct mode versus the server** becomes a protocol: a game wants exclusive fullscreen. The server
  must be able to hand the display to a client and take it back when the client exits or is asked to
  leave (`displayHandover(pid)`). Not needed for V6a-V6d; needed before any game runs next to the desktop.
- A crash of the owner still returns the console (this works today and is tested).
- Capabilities exist (`kernel/cap/capability.nim`): this is another right in a familiar mechanism, not a
  new mechanism, but minting needs a trusted spawner. Today every spawn goes through the kernel-resident
  shell, so "trusted" currently means "whatever the user typed".

**If not:** A is zero work and fine for a single-user demo; it is unsafe the moment untrusted programs
run. Since "useful" and "teaches OS design" are both stated goals, I would not ship A.

---

### D4. Who may read input?

**The problem.** The `input` topic carries every key and pointer event to anyone who subscribes. The
raylib port subscribes to it. A server that routes input by focus is pointless if any client can also
read the stream directly.

**My pick:** subscription to `input` needs a right (the same mechanism as D3). The server holds it;
clients get events from the server on their own event path. Until then the kernel console and the raylib
direct mode keep subscribing, as the right is granted when no server runs.

**Consequences.**
- The kernel console (a kernel task) also reads the topic; the "grab" logic (the console ignores events
  while a program owns the display) becomes a special case of focus, and should be rebuilt as one.
- Focus is a **new piece of state with a policy** (click-to-focus, keyboard focus follows window, who
  gets keys when no window is focused). The pointer position lives in the server (the V5e work moved it
  into the raylib platform; in the server it is global state, with a cursor image drawn by the
  compositor).
- Global keys (switch window, screen lock, a panic key to get the console back) need a decision: the
  server handles a reserved chord before routing. A **panic chord that returns the console** is cheap
  and important: without it a hung server owns a screen nobody can leave except by killing QEMU.
- Latency: every key now makes two hops (kernel to server, server to client) before the app sees it.
- Separating an `input_server` (R3) later changes only who holds the right.

**If not:** leave the topic open and document it. Acceptable for V6a-V6b (one client); not for a system
that calls itself capability-based (VISION goal 6).

---

### D5. What does the user see when the render server runs?

**The problem.** The console and the shell are kernel tasks drawing on the display. When the server owns
the display the console steps aside, and the shell has no screen and no keyboard (the server holds the
input right). So a running server **removes the only UI the OS has** unless something replaces it.

| option | meaning |
|--------|---------|
| **A. opt-in** | `rserver` is a program like `rldemo` today: you run it, you quit it (or press the panic chord) and the console returns |
| **B. terminal client** | a window that shows the console's output and sends keys to the shell |
| C. boot default | the server starts at boot and is the UI; the shell is a window |
| D. shell as a userspace program first | removes the kernel dependency (R6) |

**My pick:** A for V6a-V6b (so it is testable and cannot lock anyone out), **B as the first real client
(V6c)**, C only when B is good enough to live in, D later (it is its own large slice).

**Consequences.**
- B needs two kernel additions: (1) the console's byte stream published as an event topic (today it
  goes to the serial port and the fb console via a mirror callback) and (2) a capability-guarded way to
  inject keystrokes into the shell's input (today `consoleGetChar` reads the keyboard and serial
  directly). Both are small and both are the first steps of R5 (console server).
- The terminal client reuses `term/vt` and `gfx/` (already host-tested and byte-identical on screen),
  so it is mostly wiring. It is also the dogfood that finds protocol gaps early.
- Booting into the server (C) changes the QEMU test harness: it drives the shell through the serial
  port today and does not care about the screen; after C, tests that read the console from the
  screendump (`console` check) read the terminal window instead. The harness keeps working (serial is
  independent) but the screen evidence changes.
- Until B exists, A means "the graphical session is a demo you enter and leave". That is honest and
  safe, and it is where we are with `rldemo` today.

**If not (C first):** the OS has a desktop sooner but every mistake in the server costs the whole UI
and the test harness; I advise against it.

---

### D6. What language and build for the server?

**Facts.** `bridge/rl_server.nim` (180 lines) already decodes and executes the P0 records against raylib
(host). C ELF programs build with gcc against picolibc and `libnimix` and link raylib (done, V5b). Nim
ELF apps build `--os:standalone` with no libc and a different entry (`nimix_entry.nim`); mixing the two
has not been tried.

| option | meaning |
|--------|---------|
| **A. Nim core** (the tested `rl_server`) compiled to C, linked with raylib, picolibc and libnimix | one source for host tests and OS; needs a spike to prove the Nim runtime is happy next to picolibc |
| B. rewrite the decoder and executor in C | known toolchain; two implementations of the protocol (Nim client, C server) and a drift risk |
| C. both: C shell around Nim logic | |

**My pick:** A, gated on a **half-day spike** (V6-0): build `rl_server.nim` into an ELF on NimixOS that
draws one frame. If the spike fails, B, and the protocol is then specified in a shared table
(`rl_protocol` generates the C header) so drift is checked by a test.

**Consequences.** A makes the protocol and the server one tested artifact; it adds the first
Nim-with-libc ELF to the build (new flags, `-d:useMalloc` or a heap bridge to libnimix, `--mm:arc` with
the arena heap). B keeps the build simple and doubles the decode logic. Either way the client library
(bridge, Nim) and any C client need the same record definitions: **single-source the table**.

---

### D7. How are sessions brokered, and where is the dispatcher? (SETTLED: the dispatcher brokers)

The human confirmed 2026-11-14 that the dispatcher stands as designed: it is the convergence point for
QoS, authorization and discovery, and it brokers sessions (capability check, QoS class, ring depth,
budget), after which each side holds one end of a ring. The analogy is REST: the contract is the
interface, the library an SDK, the dispatcher the gateway.

**Consequences for V6.**
- V6 does not start with a direct `hello` on a `render` channel. It starts with dispatcher Stage 2
  (reply correlation, capability gating, session brokering, discovery), which is as large as V6a-V6c
  together and is why the core-design order puts it first (`core_design.md` M8).
- Name squatting is closed at the source: a client gets a handle from the dispatcher; it never needs
  to find the render server by name.
- The server's ELF is spawned with the right to register with the dispatcher; the dispatcher's own
  first handle reaches each program at spawn.
- Per-session budgets are granted by the dispatcher and enforced by the server.
- Withdrawn: the "direct brokering" option and its ADR "exception to axiom 1".

--------|---------|
| A. dispatcher brokers (the axiom as written) | V6 waits on dispatcher growing session brokering |
| **B. direct**: a client sends `hello` on channel `render`, the server creates a per-client channel and grants buffers | works now; a **temporary, recorded exception** to the axiom |
| C. kernel brokers | kernel policy: against the principles |

**My pick:** B now, with a one-line ADR "exception to axiom 1, ends when the dispatcher brokers
sessions", and the session API shaped so the dispatcher can sit in front of it later (the client never
names the server's channel; it asks a `connect("render")` function).

**Consequences.**
- **Name squatting**: channel names are global and first come. A program started before the server can
  create channel `render` and impersonate the server (hello, window requests, even fake display output
  to a client). Mitigation inside B: the server creates its channel at spawn through a privileged name
  reservation (D3's rights word covers it). Without it, B is unsafe.
- Budgets: the dispatcher was to grant each session a memory budget; under B the server enforces
  per-session caps itself (it already must: targets and textures are charged to the session).
- Every later feature that makes the dispatcher the hub (QoS classes, per-app priorities) has to be
  re-threaded through sessions that were created without it.

**If not (A):** purer, and V6 starts only after a dispatcher slice (sessions, caps, rings) that is as
large as V6a-V6c together. It could be done first if you would rather keep the axiom unbroken.

---

### D8. What is a window's content? (server-drawn, client-drawn, or both)

**The problem.** `render_server.md` says: server-provides by default (commands), client-side as the
measured exception. Today's raylib ELF apps draw client-side (rlsw into their own buffer) and present it.

**My pick: both, from the start.** Window content is either a **command stream** (the default, what
RUI/WASM will use) or a **surface** (a buffer plus damage, committed by the client). `PLATFORM_NIMIX`
gains one behaviour: if the `render` channel exists, `SwapScreenBuffer` commits the framebuffer as a
surface instead of calling `nimixDisplayPresent`.

**Consequences.**
- **Every existing raylib ELF app becomes a window with no source change** (`rldemo`, `rlkeys`,
  `rlmouse`, anything built on raylib). That is the cheapest large step toward "useful": real programs
  in windows, tested by pixel equality against what we have already.
- The surface lane costs copies: client buffer to server (a move, no copy) to window texture (a copy
  into the compositor target) to framebuffer (a copy) to virtio (a transfer). Measured: the last two
  are small next to rasterization (end = 4-5 % of a frame), so the copies are acceptable; damage
  rectangles keep them proportional to what changed.
- It doubles the paths to test (commands and surfaces), and gives two ways to be wrong about pixel
  format, stride, damage and clipping. The conformance tests (§5) cover both against one host
  reference.
- Surfaces make the arena problem bigger: each window holds 1-2 surface buffers (D1, D10).
- The VISION exception rule ("each exception is an ADR with its measurement") is satisfied by
  construction: the surface lane is the recorded exception; the bridge counts it.

**If not:** commands only means no existing app can be shown until the bridge's C client exists; the
first visible windows would be test clients written for the server.

---

### D9. Compositing and damage

Decision I take: **damage-limited from the first compositor**, with a test that proves the damage
result equals a full recomposite pixel for pixel. P0 showed rasterization dominates and the measurements
above agree (94-96 %); the lever is drawing less. The compositor is a pure module (window stack,
occlusion, per-window damage in, minimal screen damage out) host-tested with random window layouts
against a naive reference, the same technique as the clock and keymap vectors.

Consequences: occlusion math is the hardest part to get right and the cheapest to test; rlsw needs
scissor per window; the present becomes a list of rectangles (the kernel already takes one rectangle
per call; several calls per frame cost one syscall each, so merge rectangles when cheaper).

---

### D10. Mode, memory and budgets

**Mode.** The server owns the display mode (ABI v2): it picks one at start (default: the boot mode) and
tells clients their window and display sizes. A change of mode is a relayout event to every client.
Nothing larger than the boot framebuffer is offered (a known v2 limit), so **a 1080p desktop is
impossible until the framebuffer is allocated larger at boot** (8 MB of contiguous DMA memory).

**Memory (the quiet constraint).** Costs at 1280x800: server framebuffer 4 MB; each window surface 2-4
MB per buffer, two buffers; each client's command buffers 4 MB (D1-B); textures and targets in the
server. With 64 blocks of 2 MB:

| holder | blocks |
|--------|--------|
| server: display buffer (1280x800) | 2 |
| server: its own targets and textures (guess) | 8 |
| per client: command buffers (2 x 2 MB) | 2 |
| per client: surface, if client-drawn (2 x up to 4 MB) | 2-4 |
| 10 clients | 40 |

That is 50 of 64 blocks for ten windows, with the arena and the 32 MB task budget both binding on the
server (16 blocks). **My pick:** arena 256 MB (128 blocks, tunable), the VM 384 MB (the time page window
at 224 MB moves with it: `TimePageAddr` must stay above the arena, so it moves to 352 MB), a larger
budget class for the server (96 MB), per-session caps enforced by the server. This is BACKLOG V4b.

**Consequences.** Every test VM grows from 256 MB to 384 MB (QEMU under TCG allocates lazily; CI
runners are fine); `TimePageAddr` and the memory-window layout change (the layout test fails loudly on
a mismatch, by design). A small-buffer lane (pools) is the real fix for command buffers and is the
second reason to do the ring slice (D1) soon.

---

### D11. Fairness and failure

Decisions I take and log: the server is a single-threaded actor (one raylib, no locks), so **one slow
client stalls every client**. Mitigations: a per-turn work cap (records, pixels touched, one session
at a time in round robin), a cap on target size and count per session, and a "frame took too long"
event to the offending client; the executor refuses a frame that would exceed its pixel cap before
running it (rasterization cost is predictable from the records). It cannot preempt a running raster:
the cap bounds the worst case, it does not remove it.

Failure: the server dying releases the display and the console returns (already built and tested).
Clients get a closed-channel error and exit. There is no session recovery in V6 (the server's state is
the desktop); a supervisor that restarts the server and lets clients reconnect is a later slice.
Consequences: a bug in the compositor or raylib takes down every window at once; this is the price of
"one server, two faces" (render_server.md decision 2) and why the panic chord (D4) matters.

---

### D12. Freezing the protocol

Spawn rule: the API is frozen when the sub-project is created. **Proposal:** freeze records v1 = the 45
routed ops P0/V7b emit (shapes, text, textures, targets, blend, scissor, the rlgl calls RUI makes) plus a
`hello` with a version and feature bits, a `size/len` header for skip-unknown, per-session ids. Leave
out of v1: `SDF_*` and `BACKDROP` (they need an upstream RUI hook; the bridge reports
`isShaderValid = false` until then), `TEXT_RUN` (Pixie, V7d), `SNAPSHOT`.

Consequences: anything not in v1 degrades through the bridge's counted local fallback; adding an op later
is cheap (skip-by-len makes old servers survive new clients), removing or changing one is the expensive
case, which is why only what P0 has proven goes in. The control and event records (createWindow,
configure, input events, focus, close) are **new** and must be designed and tested before the freeze;
they are not covered by P0.

---

## 4. Cross-cutting repercussions (read these even if you only skim the decisions)

1. **The user-visible OS changes shape.** Today the OS is a text console that can lend the screen to a
   program. After V6 it is a display server with windows and the console is one client (D5). Every
   interaction, test and documentation that says "the console" needs a second reading. Done well, the
   opt-in start (D5-A) keeps both worlds.
2. **Security gets real, or does not.** D3 (display), D4 (input) and D7 (names) are one theme: without
   them a client can read every key, draw over everything, or pose as the server. VISION goal 6 ("no
   ambient authority anywhere") is violated by three existing ambient things (the `input` topic, display
   by first come, global channel names) and V6 is the point where they matter. The syscall hardening
   (V14) closed the kernel side; this is the server side.
3. **The kernel gets three new mechanisms** whatever else we decide: rights at spawn (D3/D4/D7), an
   event/console-stream publishing path (D5), and a wait primitive (D2). None is policy; all are small;
   all are shared with later servers (audio, fs, net).
4. **Latency is bounded by the weakest hop.** Until D2 is done, polling puts a floor of about 10-20 ms
   per hop under the 33 ms budget. The budget is gated only on KVM, so the CI stays green while the real
   number is unknown. I propose adding a *latency probe* test (timestamps through the whole path, logged
   not gated) in V6c, so the number exists before it matters.
5. **The test strategy transfers.** Everything built so far (golden vectors, pixel-exact screendump
   compare, acknowledgement-paced input, hostile-argument programs) applies unchanged: the compositor
   and protocol are pure and host-tested; the server is tested by pixel equality with the P0 host render;
   a hostile client program (like `abifuzz`) attacks the server's validation. Plan to write the hostile
   client **before** the server's session code, as V14 showed it pays.
6. **Three kernel models.** The server is an ELF and runs in all three; only the microkernel model has
   the isolation that makes D3/D4/D7 meaningful (in SASOS, and monolithic, a server is not separated
   from its clients by hardware). The proposal does not weaken the other two; it makes the rights tests
   run in the model where they can fail.
7. **What V6 unblocks:** V9 (the benchmark that justifies the model), V7/V8 (WASM clients), R2/R5/R6
   (graphics and console out of the kernel), V5e's focus model, V5d (damage present). **What it makes
   harder:** direct-mode apps (they must negotiate, D3), anything that wants a fixed boot screen,
   and any later per-client address space change (Stage B CR3) because surfaces rely on the arena.
8. **Cost and size.** I would not spawn this as one sub-project with one backlog. Seven slices (below),
   each a small PR. The riskiest dependency is not graphics: it is the kernel work (D2, D3/D4, rings).

## 5. How each slice is tested (done-checks)

- **Protocol (host):** decode/validate fuzz (bad lengths, ids, stack depth, budgets); remote output
  byte-identical to direct (P0 already does this for 82,815 pixels).
- **Compositor (host):** random window layouts and damage sequences; the incremental result equals the
  naive full composite on every frame.
- **Server (QEMU):** a scripted C client sends hand-built records; the screendump equals the host render
  pixel for pixel. Two clients overlap; z-order and occlusion pixel-exact. A hostile client (wrong
  lengths, other sessions' ids, absurd sizes, a flood) is refused and the server and other clients are
  unaffected.
- **Input:** keys and pointer events go to the focused window only, tested by acknowledgement-paced
  injection as in `keys-*`/`mouse-*`; a non-focused client never sees them; the panic chord returns the console.
- **Surfaces:** `rldemo` run in a window is pixel-equal to its direct-mode render inside the window's rect.
- **Counts (gated everywhere):** records per frame, bytes per frame, kernel calls per frame, zero frames
  presented when idle. **Times:** logged under TCG, gated only on KVM (VISION).

## 6. The slices (what I would build, in order, each a small PR)

| slice | content | needs | ends with |
|-------|---------|-------|-----------|
| **V6-0 spike** | `rl_server.nim` as an ELF drawing one frame; the Nim+picolibc build question (D6); a frame-time baseline (`rlbench`, done) | nothing | a yes/no on D6 |
| **V6a executor** | server ELF: control channel, `hello`, one session, records into a target, present through ABI v2; a scripted C client; hostile client | D1 (B), D3, D7 (B), D12 | pixel-equal frame from a client, hostile client refused |
| **V6b windows** | multiple sessions, window stack, pure compositor with damage, z-order, server-drawn title bars, mode owned by the server | D8, D9, D10 | overlapping windows pixel-equal to the host composite |
| **V6c input and terminal** | input right and focus, pointer, panic chord; console stream topic and key injection; the terminal client | D4, D5 | typing in a window runs shell commands; latency probe logged |
| **V6d surfaces** | `PLATFORM_NIMIX` commits surfaces when a server exists; `rldemo`/`rlkeys`/`rlmouse` as windows | D8 | existing raylib apps run in windows with no source change |
| **V6e transport** | ring syscalls + a small-buffer lane behind `transport`; the 1-call-per-frame count gate | D1 | calls/frame <= 1 (+ wake); command buffers stop costing 2 MB |
| **V6f block-on-wake** | scheduler wait, sub-tick timer, `wait()` swapped in | D2 | idle server uses no wakeups; latency probe under budget on KVM |
| **V6g hardening and handover** | exclusive-fullscreen handover (games), per-turn work caps tuned, session cleanup on crash | D3, D11 | a direct-mode app takes and returns the display next to the desktop |

V6-0, V6a, V6b are a first PR set that leaves the OS bootable as it is today (opt-in). Order of the kernel
slices (rights, console stream, rings, wait) can move; V6f is the one I would pull forward if you care
about responsiveness before windows.

## 7. What I need from you, and what happens on each answer

Five answers unblock V6-0/V6a; the rest I will take and log.

1. **D1** transport: is "channel messages + moved frame buffers now, rings later behind an interface" acceptable,
   knowing it misses the 1-call target and spends arena until V6e?
2. **D3/D4/D7** (one theme): is a **rights word at spawn** the mechanism (display, input, name reservation),
   with a direct-mode fallback when no server runs? Or do you want the dispatcher to broker sessions
   first (A in D7), accepting a delay?
3. **D5** the visible plan: opt-in first, terminal window as the first client, boot-default later?
4. **D8** both lanes (commands + surfaces) from the start?
5. **D10** the 256 MB arena / 384 MB VM / bigger server budget (V4b), now rather than later?

On "yes to my picks": I record D1-D12 in DECISIONS.md, freeze the three interfaces in ARCHITECTURE.md,
SPAWN `subprojects/render_server` with its own VISION/BACKLOG (first task: the V6-0 spike), and build
V6a. On a different answer to D3/D4/D7 I redo only §3 D3/D4/D7 and the slice order; the other decisions
do not depend on it. Anything you want to change in the seam itself (§1) is the one change that costs
rework in every slice, so that is the part to read twice.

## 8. What I do not know yet (stated so it is not assumed)

- Whether Nim's runtime links cleanly next to picolibc and `libnimix` (the V6-0 spike answers it).
- Real rlsw cost per widget on KVM-class hardware (TCG numbers are an emulator's; P0's host number is
  for one scene). V9 is where this is judged; V6 only has to not make it worse.
- The wake latency of the event/channel path in practice (no probe exists yet; V6c adds one).
- Whether 4 queued buffer handles per message is enough for a window with several textures per frame
  (textures arrive as separate moved buffers); I expect yes, and the control path can chunk.
- Pool/small-buffer lane design (D1-D): not designed; it is the second half of the ring slice.
