# SURVEY — RUI2 (vendor/rui2) as NimixOS's GUI toolkit

Pinned: `vendor/rui2` @ `0038051` (git submodule). Surveyed 2026-11-03.
Size: ~42k lines of Nim in 9 packages (`rui_widgets` 21k, `rui_core` 7k,
`rui_drawing` 7k, `rui` 2.7k, `rui_scripting` 1.5k, `rui_events` 1.4k,
`rui_hittest` 0.6k, `rui_shaped` 0.6k, `rui_windows` 0.4k).

## 1. Immediate-mode or retained?

**Immediate mode with per-widget caching** (ARCHITECTURE.md). The UI is a
function of state; a two-pass loop runs layout, then renders bottom-up. Each
dirty widget repaints into **its own `RenderTexture2D`** and composites its
children's cached textures; a clean widget is a texture blit, and an idle app
sleeps.
→ The render server must hold **server-side render targets** that the app
creates and refers to by id. An immediate draw stream is not enough. This
is also where the model wins: a steady-state frame is a handful of blits.

## 2. Which raylib calls (the minimum command set)

84 distinct naylib calls (identifiers cross-referenced with naylib's API).
By group, with call-site counts:

| group | calls |
|-------|-------|
| shapes | drawLine(79) drawRectangle(14) drawCircle(13) drawRectangleLines(12) drawRing(6) drawTriangle(4) drawRectangleGradientH/V(3/2) drawRectangleRounded(2) drawCircleLines(3) drawRectangleRoundedLines(1) clearBackground(9) |
| text | measureText(113) drawText(31) — but see §5: real text goes through Pango |
| textures / targets | drawTexture(17) loadTextureFromImage(5) loadTexture(3) loadRenderTexture(3) beginTextureMode/endTextureMode(3) setTextureFilter(4) setTextureWrap(1) unloadTexture(1) loadTextureFromData(1); **rlgl** framebuffer/texture calls in `rui_core/main_loop.nim` (colour-only widget targets) and `rui_drawing/backdrop.nim` |
| state | beginBlendMode/endBlendMode(6) beginScissorMode/endScissorMode(1) fade(12) |
| shaders | setShaderValue(43) getShaderLocation(8) begin/endShaderMode(5) loadShaderFromMemory(4) isShaderValid(3), used ONLY by `rui_drawing/primitives/sdf.nim` (anti-aliased rounded box, soft shadow, round-capped segment, triangle) and `backdrop.nim` (blur/saturate/tint behind modals). Both **already fall back** when a shader can't draw. |
| images | loadImage(5) loadImageColors(3) imageAlphaPremultiply(3) loadImageFromMemory(1) loadImageFromScreen(1) genImageColor(1) exportImage(1) |
| window / input | initWindow beginDrawing/endDrawing windowShouldClose closeWindow setTargetFPS getTime getScreenWidth/Height isWindowReady/Resized setWindow* getMousePosition/Delta/WheelMove isMouseButton* isKeyDown getKeyPressed getCharPressed getTouch* setMouseCursor setExitKey pollInputEvents clipboard get/set, dropped files |

→ The protocol's **draw** commands are about 25 records. The shader
group becomes **native semantic commands** (`sdfBox`, `sdfShadow`,
`sdfSegment`, `sdfTriangle`, `backdrop`) because GLSL can't run on a
software renderer. Window and input calls belong on the app_server control
channel and the event ring, not in the draw stream.

## 3. Threads, blocking I/O, direct texture handles?

- **Threads: few and well fenced.** One UI thread. `runInBackground`
  (`rui_core/background.nim`) is one worker thread with a FIFO queue, and
  `Mailbox[T]` (`rui_core/mailbox.nim`) passes copied values back to the UI
  thread between frames. Also used by the scripting poller and
  `paged_source.nim`. This **maps directly onto actors**: the UI is an
  actor, the background worker another task, and Mailbox is an actor
  mailbox. No locks in widget code.
- **Blocking I/O:** theme files (YAML), images from files, the scripting
  file-poll protocol (std/os, std/json, std/times). The scripting package
  is a test facility and can be left out of a NimixOS build; theme and
  image loads go to fs_server (lent buffers).
- **Direct texture handles:** **yes.** `main_loop.nim` builds colour-only
  render targets with raw `rlgl` framebuffer/texture ids, and frees them by
  id. → In the command protocol these become **app-chosen resource ids**
  (create/destroy commands, no round trip). `loadImageFromScreen` (modal
  backdrop freeze) becomes a server-side `snapshot → texture` command, never
  a pixel readback.
- **Platform:** `rui_shaped` loads X11/Win32 via `std/dynlib` (shaped
  windows). Exclude it on NimixOS, where app_server owns window shape.

## 4. Does it build for WASM? Nim version and memory manager?

- **No WASM target today**: no wasm/emscripten configuration anywhere.
- **Nim ≥ 2.0**, default memory manager (**ORC**). `Widget.parent` closes
  reference cycles (parent ↔ children), so **ARC alone would leak trees**.
  NimixOS's WASM SDK builds `--mm:arc`; RUI needs `--mm:orc`, or `parent`
  marked `{.cursor.}`. That is an upstream decision for rui2.
- Dependencies: **naylib** (raylib C), **NimYAML** (pure Nim, fine), and the
  **Pango/PangoCairo/Cairo** C libraries for all text.
- `--threads:off` breaks `background.nim`/`mailbox.nim`. On NimixOS they
  need an actor-backed implementation behind the same API.

## 5. The hard part: text

Every text path (`measureText`, `drawText`, the TextArea engine: caret
movement, BiDi, soft breaks, hit-testing) goes through **Pango + Cairo**
(`rui_drawing/pango_text.nim`): glib, HarfBuzz, FreeType, fontconfig.
That is heavy, not freestanding, and the API is **synchronous**:
layout calls `measure`/`softBreaks`/`cursorPosition` many times per frame.
→ Text **measurement must stay local to the app** (a round trip per
measure would blow every budget). Drawing can be a command. Options are in
the protocol proposal.

## Verdict

**Adopt RUI2 unchanged where possible, behind shims:**
- a NimixOS `raylib`/`rlgl` module pair (same names and types as naylib)
  whose procs *encode draw commands* instead of calling C;
- an actor-backed `background`/`mailbox`;
- a text engine behind `pango_text`'s API.

Upstream changes to propose to rui2 (small, generally useful):
- a backend hook for the semantic SDF primitives (instead of
  shader-or-fallback);
- an ORC/`{.cursor.}` choice for `parent`;
- making `rui_scripting` and `rui_shaped` optional at compile time.

Server side: **adopt raylib 6.0 with `rlsw`**, its official software
renderer, already used GPU-less on ESP32 with a custom platform reading the
colour buffer. Our `PLATFORM_NIMIX` blits it to virtio-gpu. Rejected:
writing our own rasterizer for raylib (rlsw exists and is maintained
upstream); keeping GLSL (no GPU); Pango in-kernel or in-server (synchronous
measurement must be app-local).

## Addendum 2026-11-03 — text engine options (human: RUI is ours to change)

Surveyed from source (read only):

| option | what it really is | fit |
|--------|-------------------|-----|
| **treeform/typography** | pure Nim, MIT, but **retired**: its README says it was integrated into Pixie and is "no longer being actively worked on" | use its successor, Pixie |
| **treeform/pixie** (6.1.0, MIT, active Sep 2026) | **pure Nim** fonts + typesetting + rasterization: TTF/OTF parsing from bytes (`parseTtf(string)`), kerning (kern + GPOS), `typeset(spans, bounds, align, wrap)` → `Arrangement{lines, spans, fonts, runes, positions, selectionRects}`, `layoutBounds`, `fillText`. Deps all pure Nim (vmath, chroma, bumpy, zippy, flatty, crunchy, nimsimd). SIMD only `when allowSimd and defined(amd64)`, so wasm32 takes the scalar path. `{.raises: [].}` on typeset | **the v1 engine.** Arrangement covers RUI's text API: measure → `layoutBounds`, softBreaks → `lines`, cursorPosition → `positions`, indexFromPosition → hit-test on `selectionRects`, rich text → `spans`. Gaps: no GSUB (no ligatures), no BiDi, one glyph per rune |
| **elcritch/harfbuzzy** (0.7.0, MIT, active Oct 2026) | **not pure Nim**: idiomatic wrappers over the HarfBuzz C/C++ API, which `nimbase/harfbuzz-nim` supplies by **linking the system HarfBuzz via pkg-config**, plus FriBidi (C) for paragraph bidi | **the complex-script path, later.** Its `shapeParagraph` / `visualRuns` API is the right shape, but it needs HarfBuzz (portable C++, no exceptions/RTTI; it builds for wasm, cf. harfbuzzjs) and FriBidi ported to NimixOS first. Parked until the first RTL/complex-script user |
| Pango/Cairo (RUI today) | C: glib, fontconfig, FreeType, HarfBuzz, Cairo | keep on desktop; not ported to NimixOS |

**Recommendation:**
- **RUI gains a text-backend seam** (its `pango_text` API is already the
  right interface), with two backends: Pango (desktop, today) and Pixie
  (pure Nim; desktop *and* NimixOS). This is an upstream change to rui2,
  which the human owns, and it also frees desktop RUI from requiring
  system Pango.
- The **same Pixie code on both sides of the protocol:** the app typesets
  (measure, wrap, caret, hit-test) locally from a sealed shared font; the
  server rasterizes the glyphs the app positioned (`TEXT_RUN`). Identical
  metrics by construction. stb_truetype is dropped from the plan: Pixie
  avoids C (and libm) in WASM apps.
- **Check in V7:** Pixie's font path in wasm32 needs only
  `sqrt/floor/ceil/round` (native wasm ops); any trig used by its path
  code must resolve in the NimixOS WASM runtime.
