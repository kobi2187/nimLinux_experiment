# Render server: raylib provides, apps describe — proposal (NOT frozen)

Status: **AGREED 2026-11-03** (human: "let's do that", with the raylib bridge). Record-level details are frozen at V6 spawn, after prototype P0 measures. It amends the agreed
app_server proposal (client-side rendering) into a hybrid. Inputs: the
human's side chat, `docs/surveys/rui2.md`, and VISION §Rendering model and
budgets. Decisions are in §6.

## 1. The decision

**raylib runs once, natively, as the render server.** Apps describe what to
draw; the server owns the pixels.

```
WASM app (RUI2 logic)                    render server (ELF, tcRealtime actor)
  layout, state, input handling            raylib 6 + rlsw (software rasterizer)
  `raylib` shim → draw commands ──ring──▶   executes commands into server-owned
  text measured locally                     targets, composites windows,
                     ◀──event ring── input  presents damaged rects to virtio-gpu
```

- **Default (server provides):** apps send draw commands
  (docs/proposals/draw_protocol.md). They hold no pixels, no GL and no
  raylib; WASM apps stay small and sandboxed.
- **Exception (client-side or direct):** an ELF app or game that misses a
  budget in the default model, for a reason that can't be fixed inside it,
  renders into its own surface buffers (the agreed buffers swapchain) or
  takes direct scanout. Each exception is an ADR with its measurement
  (VISION).

app_server and the render server are **one ELF server with two faces**:
- the window manager (windows, focus, routing; the agreed control
  protocol);
- the compositor and renderer (commands for server-provided windows,
  surfaces for client-rendered ones).

They're one process because both own the same pixels. Splitting them would
put a copy and a hop in every frame.

## 2. Why this fits NimixOS

- **Single-threaded raylib = one actor.** The render server is a CPS actor
  in the `tcRealtime` class. Its mailbox receives `ringSubmit` wakes and
  input; a frame is one turn of the loop.
- **Mechanism vs policy:** the kernel only moves buffers and wakes actors.
  All rendering policy (what to raster, when to present, damage) is in the
  server.
- **Isolation by construction:** apps can't touch another app's pixels or
  the framebuffer. Resource ids are per session.
- **WASM stays lean (isolation only, per VISION):** the 84-call raylib
  surface RUI uses becomes a thin shim that writes commands. Hot leaf work
  (text layout) is a native host import from the app's ELF WASM host. No C,
  GL or libm in the app.

## 3. The raylib port (server side)

| piece | plan | prior art |
|-------|------|-----------|
| rasterizer | raylib **6.0 `rlsw`** (`GRAPHICS_API_OPENGL_SOFTWARE`) | official, upstream; ESP32 builds read its colour buffer directly |
| platform | `PLATFORM_NIMIX`: init = virtio-gpu framebuffer; swap = blit rlsw's colour buffer (the damage only) + `virtioGpuPresentRect`; time = fine clock; input = event ring | raylib's `PLATFORM_CUSTOM` template; avoids the GLFW path whose swap never blits rlsw ([discussion #5880](https://github.com/raysan5/raylib/discussions/5880)) |
| libc / libm | **picolibc** (BSD, built for embedded, has a libm), or musl's math only | the side chat; SURVEY task V2 picks one |
| clock | a fine monotonic clock: TSC calibrated against the PIT (or the APIC timer) for `GetTime`, frame pacing and latency measurement; the PIT stays the scheduler tick | standard practice |
| memory | the server needs well over 4 MB (rlsw targets, textures): a **large-region class**, or buffers from the arena as its heap | buffers Stage A arena / region allocator |
| audio | not in the render server. raylib's miniaudio thread is replaced by a **thread-free backend feeding virtio-snd through a session ring**, in the audio server | the side chat; buffers rings |
| fonts / text | **Pixie** (pure Nim) on both sides: apps typeset, the server rasterizes the positioned glyphs from the same **sealed font buffers** (draw_protocol §5); HarfBuzz via harfbuzzy later for complex scripts | treeform/pixie, elcritch/harfbuzzy |

## 4. What the app side needs (WASM + RUI)

- **Memory manager:** `--mm:orc` for WASM, or a `{.cursor.}` parent
  upstream in rui2. RUI's widget trees are cyclic.
- **Shims, unchanged RUI where possible:**
  - the **raylib bridge** (draw_protocol §7): naylib-compatible
    `raylib`/`rlgl`; per op `direct` (in-process raylib), `remote`
    (commands) or `hybrid`; apps don't change;
  - `background`/`mailbox` (actors);
  - `pango_text` API → the local text engine.
- **Larger linear memory** than today's 1 MB WASM arena.
- **Host calls:** buffer and ring operations (buffers B8 rest).

## 5. Risks, and how each is measured

- **Command overhead vs in-process raylib:** the comparison benchmark (V9),
  against the budgets.
- **TCG speed** hides real costs: counts gate CI; times are judged under
  KVM.
- **Text fidelity** without Pango (no complex shaping or BiDi at first):
  stated as a v1 limitation; a HarfBuzz-in-server option is parked with a
  resolving signal (first RTL user).

## 6. Decisions for agreement (my pick first)

1. **raylib as one native render server; apps send draw commands** (the
   hybrid above), reached through the **raylib bridge**, so existing
   raylib/RUI apps don't change and the route is decided per op. I'd pick yes. This amends app_server's "client-side
   rendering" to "server provides by default, client-side as the measured
   exception".
2. **One server, two faces** (window manager + renderer). I'd pick yes; the
   alternative is two servers with a copy per frame.
3. **Adopt raylib 6.0 rlsw** for rasterizing. I'd pick yes; the alternative
   is our own rasterizer.
4. **picolibc vs musl math:** surveyed in V2; my lean is picolibc (whole
   libc + libm, embedded-first, BSD).
5. **Fine clock = calibrated TSC**, with the PIT as the scheduler tick.
   I'd pick yes.
