# app_server API — proposal (NOT frozen)

Status: **PROPOSED 2026-10-27** — for convergence with the human before the
seam is frozen (AGENTS.md §SPAWN). Decisions needed are in §8.

## 1. What we keep from BeOS, and what we change

| BeOS | NimixOS |
|------|---------|
| `app_server` owns the screen; apps are clients | same — an ELF server owns the virtio-gpu display |
| `input_server` is a separate server feeding `app_server` | same — devices + keymaps live in input_server |
| `BApplication` / `BWindow` = a `BLooper` (one OS thread per window) | one **actor** (CPS fiber + mailbox, `runtime/actor.nim`) per window — no OS threads |
| `BMessage` over ports | MsgPack control messages over a server channel (≤256 B) |
| server-side drawing: the app sends draw commands, the server renders | **client-side rendering**: the app draws into its own surface (gfx/, raylib later); the server only composites |
| `BDirectWindow` (games draw straight to the frame buffer) | **direct mode**: a fullscreen surface is scanned out as-is, zero copy |
| server-drawn decorator (yellow tab) | same — server draws title bars/borders, so every app gets them free |
| everything is a message | pixels and input events move through **shared memory** (rings + buffers); messages are only doorbells and control |

Why client-side rendering: there's no drawing protocol to version and grow.
Apps render in parallel, and pixels never cross IPC. It fits regions as the
unit of memory and capabilities.

## 2. Decomposition (three seams, one frozen protocol)

```
 input_server (ELF)                app_server (ELF)                      app (ELF or WASM)
 virtio-input/PS2 → keymap ──ev──▶ focus + routing ──event ring──▶  ui/ client lib
                                   z-order, decorations              window actors, Canvas
                                   damage compositor   ◀──surface──  back/front buffers
                                   ──▶ virtio-gpu (PresentRect / direct scanout)
```

- `ui/` (client library, Nim): BeOS-flavoured API over the protocol; the
  only thing apps link. WASM apps get it as host calls.
- **Protocol** (the frozen API): control messages (§4) + the surface layout
  (§3) + event records (§5).
- `app_server` (sub-project, SPAWN): compositor, window manager, routing.
- `input_server` (sub-project, later): moves `input/evdev_keymap` out of the
  kernel console path; publishes normalized key/pointer events.

## 3. Surfaces — shared memory, lock-free

> **Superseded in part by `docs/proposals/bulk_data.md` (2026-10-27):** no
> ad-hoc shared region. A surface is a swapchain of *buffers*: the app
> **moves** a buffer to app_server on commit and gets it back on release, so
> the two sides never touch the same pixels at once (enforced, not promised).
> The control block's counters become messages on the control channel, and
> the event ring below becomes a kernel **ring** (producer end held by the
> server, consumer end by the app). The frame protocol, damage rects, and
> triple buffering are unchanged. The layout below is kept for reference.

A window's pixels live in a **surface region** that the *client* allocates
(memory is charged to the app; the server can't be made to allocate) and
grants to app_server with a region capability (refcounted: a dying client
can't pull memory out from under the compositor).

```
surface region
┌─ page 0: SurfaceCtl (shared control block) ───────────────────────────┐
│ magic, version, width, height, stride, format (XRGB8888)              │
│ bufCount (2 or 3), bufOffset[3]                                       │
│ commitSeq   (client: release-store)   ─┐ one-writer counters, no locks│
│ commitBuf, damage[8] rects, damageN    │ client fills, then bumps seq │
│ consumedSeq (server: release-store)   ─┘ "I'm done reading that buffer"│
│ event ring: head (server), tail (client), 64 × 32-byte records (§5)   │
├─ buffer 0 ────────────────────────────────────────────────────────────┤
├─ buffer 1 (, buffer 2) ───────────────────────────────────────────────┤
└───────────────────────────────────────────────────────────────────────┘
```

Frame protocol (no message per pixel, one tiny doorbell per frame):
1. The client draws into a buffer it owns: not `commitBuf`, and not one the
   server hasn't released (`consumedSeq`).
2. The client writes the damage rects and `commitBuf`, then release-stores
   `commitSeq + 1`.
3. Doorbell: `commit(win)` on the control channel. With wake-on-deliver
   (Phase E) this becomes a notify on the server's mailbox.
4. The server acquire-loads `commitSeq` and composites only the damage. It
   release-stores `consumedSeq` when it has copied the pixels out, or, in
   direct mode, when the next buffer is scanned out.

Triple buffering lets a fast renderer never block on the compositor. The
server coalesces commits it hasn't serviced yet: only the newest frame counts.

## 4. Control messages (client → "app" channel, MsgPack, ≤256 B)

| op | args | reply (event on `app.reply.<pid>`) |
|----|------|-------|
| `hello` | protoVersion, appName | serverVersion, screen w/h, formats |
| `createWindow` | title, frame{x,y,w,h}, flags, look, surfaceCap | winId (or error) |
| `destroyWindow` | winId | — |
| `configure` | winId, frame?, title?, flags? (move/resize/show/hide/raise/fullscreen/direct) | `configure` event with the effective state |
| `attachSurface` | winId, surfaceCap | — (on resize: the client supplies a new surface) |
| `commit` | winId, seq | — (doorbell only; data is in SurfaceCtl) |
| `setCursor` | winId, shape | — (later) |

Flags: `resizable`, `noDecor`, `modal`, `floating`, `fullscreen`, `direct`.
Every message is capability-gated: the client presents the `app` send
capability it got at `hello`. Window ids are scoped to the client's pid.

## 5. Events (server → client): ring in SurfaceCtl, 32-byte records

```
EventRec = { kind: u16, flags: u16, timeMs: u32, a, b, c, d: i32, e: u64 }
kinds: Configure(w,h,state) Focus(in/out) Key(code, char, mods, down/repeat)
       Pointer(x, y, buttons, wheel) Enter/Leave CloseRequested
       FrameDone(seq)   ← pacing, like Wayland's frame callback
       ScreenChanged(w, h)
```

This is a single-producer/single-consumer ring (head written only by the
server, tail only by the client): no locks and no allocation, and events
are never dropped silently. If the ring is full, the server coalesces
pointer motion and keeps keys. The wakeup is an event-bus doorbell on
`app.ev.<pid>`, which carries no payload.

## 6. Client library sketch (`ui/`, Nim)

```nim
let app = uiConnect("terminal")                       # hello
let win = app.newWindow("Terminal", rect(80, 60, 800, 480), {wfResizable})
win.onKey = proc(e: KeyEvent) = term.input(e.ch)
win.onConfigure = proc(w, h: int) = term.resize(w div 8, h div 16)
win.onFrame = proc(c: Canvas): Rect =                 # back buffer as a gfx Canvas
  view.render(term)                                   # returns damage
app.run()        # each window is an actor: drain ring → handlers → frame → commit
```

The terminal app is then roughly `term/` + `gfx/` + 40 lines of glue, and
the kernel fb console becomes the boot/fallback console.

## 7. Compositor internals (server-private, free to change)

- **Window list:** a z-ordered array (n is small; cache friendly).
- **Damage:** per output, a short list of rects, merged when they overlap
  heavily. Only damaged areas are composited and presented
  (`virtioGpuPresentRect`).
- **Visibility:** each window keeps its visible region (rect list) under the
  windows above it, recomputed only on z-order or geometry changes. Blits
  then never paint pixels that will be overwritten (BeOS-style clipping).
- **Opaque windows:** windows are opaque in v1, so compositing is a straight
  copy (memcpy per row). Alpha comes later, per window.
- **Direct mode:** a fullscreen `direct` window gets SET_SCANOUT to its own
  virtio-gpu resource, so there is no copy at all (the BDirectWindow
  analogue).
- **Run loop:** the server itself is an actor loop: control channel, commits,
  input events, then compose. It runs in the `tcRealtime` class for steady
  frame pacing.

## 8. Decisions needed (my pick first)

1. **Rendering model:** I'd pick *client-side + server decorations*. The
   alternative is BeOS server-side drawing commands. Client-side is simpler
   to freeze, faster, and lets raylib and games work unchanged.
2. **Who allocates surface memory:** I'd pick the *client*, granting a
   capability to the server. The alternative is the server allocating and
   granting to the client. With client allocation, memory is accounted to
   the app and the server can't be DoS'd.
3. **Surface memory pool:** today there are 16 × 4 MB regions in total, and
   a double-buffered 1280×800 surface needs 8 MB. I'd pick a *separate
   surface pool with large/variable-size regions* (a new region class).
   Alternatives: multi-slot regions, or capping windows at 4 MB.
4. **Event path:** I'd pick the *SPSC ring in shared memory plus a
   doorbell*. The alternative is per-event messages on the event bus (512 B
   copies, droppable).
5. **input_server as a separate server** (BeOS layout): I'd pick *yes*, but
   later. Until then app_server subscribes to `input` directly, through the
   same keymap lib.
6. **WASM apps:** their surface lives in linear memory, so for now the host
   copies the damaged rects on commit. Zero copy comes once wasm memory can
   be region-backed.

## 9. Kernel prerequisites this implies (cross-cutting)

- **K1 capability transfer:** pass a region capability inside a channel
  message to another pid (today `grantRegion` mints only for the caller).
- **K2 surface pool:** a region class sized for surfaces (decision 3).
- **K3 display handoff:** the fb console yields the display when app_server
  starts and reclaims it if app_server dies.
- **K4 (Phase E) wake-on-deliver:** idle clients and the server sleep
  instead of polling. Interim: poll + `yield`.

## 10. Plan once agreed

1. Freeze §3–§5 as the protocol in ARCHITECTURE.md; stub `ui/` against it.
2. K1 + K2 + K3 in the kernel.
3. SPAWN `subprojects/app_server/`: its first task is a SURVEY (Wayland
   `wl_shm`, Haiku app_server, Arcan, Sway damage tracking).
4. Terminal app in a window; done-check: two terminals, focus routing,
   screendump pixel test.
