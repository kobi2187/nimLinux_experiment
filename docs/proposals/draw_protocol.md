# RUI ↔ render server draw-command protocol — proposal (NOT frozen)

Status: **PROPOSED 2026-11-03**, for agreement after render_server.md.
Sources: `docs/surveys/rui2.md` (the 84 raylib calls RUI makes, its
per-widget texture cache, shaders only for SDF primitives and the backdrop,
Pango text), `docs/proposals/bulk_data.md` (frozen transport) and
VISION's budgets.

## 1. Shape

```
app frame:  encode commands into a command buffer (≤240 B: inline ring slot)
            ringPush(BufRef or inline) → ringSubmit      ← 1 kernel call
server:     validate → execute into session targets → composite → present damage
            frameDone(seq) + the command buffer back on the release ring
```

- **Session:** at `createWindow` the dispatcher brokers a render session.
  The app gets the producer end of the **command ring** and the consumer end
  of the **event ring**; the server gets the opposite ends. A session budget
  caps server-side memory (textures, targets) on the app's behalf.
- **Command buffers** come from the app's own budget, double-buffered, and
  are **moved** to the server per frame and moved back on release. A tiny
  frame (one blit + present) fits **inline** in one ring slot: no buffer, no
  ownership flip.
- **Window and input** stay on the agreed app_server control channel and
  the event ring: initWindow, cursor, clipboard, size, focus. They never
  appear in the draw stream.

## 2. Encoding (data plane: flat binary, not MsgPack)

Records are little-endian, 4-byte aligned:

```
Record = { op: u8, flags: u8, len: u16 }  +  payload (len = total bytes)
```

- Coordinates `f32`; colours `u32` RGBA (non-premultiplied, as RUI paints).
- Ids `u32`, app-chosen, per session.
- Strings: `u16` byte length + UTF-8, padded to 4 bytes.
- **Unknown op → skip by `len`**: old servers survive new apps, and the
  feature bits in `hello` say what is available.
- Zero-parse: a record is read in place (FlatBuffers-style fixed layout).
  MsgPack stays the control-plane format, per VISION.

## 3. Commands (v1, about 30 ops)

| group | ops | replaces (raylib/rlgl) |
|-------|-----|------------------------|
| frame | `BEGIN_FRAME(seq)`, `END_FRAME(seq, damage rect)` | beginDrawing/endDrawing; END_FRAME presents only damage |
| targets | `CREATE_TARGET(id,w,h)`, `DESTROY(id)`, `BEGIN_TARGET(id)`, `END_TARGET` (stack ≤ 8) | loadRenderTexture / rlgl framebuffer+texture, begin/endTextureMode, unloadTexture: RUI's per-widget cache |
| textures | `CREATE_TEXTURE(id,w,h,fmt, BufRef pixels)`, `CREATE_TEXTURE_ENCODED(id, BufRef png/qoi)`, `TEX_PARAMS(id, filter, wrap)` | loadTexture*, loadImage*, setTextureFilter/Wrap. The **server decodes** (raylib's image loaders); pixels arrive by moved or sealed buffer |
| state | `SCISSOR_PUSH(rect)`, `SCISSOR_POP`, `BLEND(mode)` | begin/endScissorMode, begin/endBlendMode |
| shapes | `CLEAR(c)`, `RECT(r,c)`, `RECT_LINES(r,thick,c)`, `RECT_GRADIENT(r,c0..c3)`, `RECT_ROUNDED(r,roundness,segs,c)`, `RECT_ROUNDED_LINES(…)`, `LINE(p0,p1,thick,c)`, `CIRCLE(ctr,rad,c)`, `CIRCLE_LINES(…)`, `RING(ctr,ri,ro,a0,a1,segs,c)`, `TRIANGLE(p0,p1,p2,c)` | the shapes group, one to one |
| **semantic** | `SDF_BOX(r, radii[4], fill, borderW, borderC)`, `SDF_SHADOW(r, radius, blur, offset, c)`, `SDF_SEGMENT(p0,p1,width,c)`, `SDF_TRIANGLE(p0,p1,p2,c)`, `BACKDROP(srcTex, dst, blur, saturation, tint)` | RUI's GLSL (sdf.nim, backdrop.nim). The server implements each as an anti-aliased software primitive. **Needs one upstream hook in rui2.** |
| blit | `DRAW_TEXTURE(id, src, dst, tint)` | drawTexture / Rec / Pro: composites cached widget textures |
| snapshot | `SNAPSHOT(dstTex, srcRect)` | loadImageFromScreen (modal freeze), with no pixel readback |
| text | `FONT(id, BufRef sealed font)`, `TEXT(fontId, size, pos, c, utf8)`, `TEXT_RUN(fontId, size, pos, c, glyphs[])` | drawText / Pango drawing (§5) |

Rare synchronous needs (`exportImage`, screenshot to file) go as async
control requests carrying a lent buffer, never in the frame.

## 4. Validation and isolation

The server checks every record:
- `len` within the stream, and the op's minimum size;
- ids present in **this session's** tables;
- sizes within the session budget;
- target stack depth ≤ 8;
- `BufRef`s through `bufRefCheck`.

A bad record ends the frame with an error event; the app is never trusted
and other sessions are never touched. Resource ids are per session, so an
app can only name its own targets.

## 5. Text: typeset in the app, rasterized by the server, with the same code

RUI measures synchronously, many times per layout pass (`measure`,
`softBreaks`, `cursorPosition`, `indexFromPosition`). A round trip per
measure would break the frame budget, so **typesetting is app-local**.

**Pick: Pixie (pure Nim, MIT) on both sides of the protocol, over the same
font bytes** (survey addendum, docs/surveys/rui2.md):
1. The server loads fonts and shares each as a **sealed buffer**
   (`tmShare`), so every app parses the same bytes.
2. **App:** RUI's text backend calls Pixie's `typeset` and keeps the
   `Arrangement` (lines, positions, selectionRects). That covers measure,
   wrap, caret and hit-test, with no C and no libm.
3. **Draw:** `TEXT_RUN(fontId, size, color, glyphs[{rune, x, y}])` sends
   the positions the app computed. The server rasterizes those glyphs with
   Pixie from the same font into a per-(font, size) glyph cache, so what
   was measured is what is drawn. `TEXT(utf8)` stays for simple callers;
   the server typesets it with the same Pixie code.
4. **RUI change (upstream, owned by the human):** a text-backend seam
   behind `pango_text`'s API, with Pango for desktop today and Pixie for
   desktop and NimixOS.
- **Bootstrap:** the Spleen 8×16 bitmap font (gfx/) as font id 0.
- **Not in v1:** ligatures (no GSUB), complex shaping and BiDi
  (`hasRtl` → false). **Parked**, resolving signal: the first RTL or
  complex-script user. The path then is elcritch/harfbuzzy (HarfBuzz +
  FriBidi wrappers) behind the same seam, once HarfBuzz and FriBidi are
  ported to NimixOS. The protocol doesn't change: `TEXT_RUN` already
  carries shaped glyphs.

## 6. Budget check (designed, to be measured)

A steady-state frame where one button changes:

| step | records |
|------|---------|
| `BEGIN_FRAME` + `BEGIN_TARGET` | 2 |
| ~8 shape / text records | 8 |
| `END_TARGET` + 3 `DRAW_TEXTURE` blits up the tree | 4 |
| `END_FRAME` | 1 |
| **total** | **~15 records, ~0.6 KB** |

That is within ≤ 200 commands and ≤ 16 KB, and costs **1 `ringSubmit`**
plus the server's present.

## 7. The app side: the `raylib` shim

`vendor/rui2` compiles unchanged against NimixOS modules named `raylib` and
`rlgl` (path override in the WASM build):
- the same type names and layouts as naylib (`Rectangle`, `Color`,
  `Texture`, `RenderTexture2D`, …);
- each drawing proc appends a record;
- `loadRenderTexture` and the rlgl framebuffer calls allocate session ids;
- `isShaderValid` returns false, so RUI takes its fallback path, until the
  upstream SDF hook lands.

## 8. Decisions for agreement

1. **Flat binary records with skip-by-len**, inline for tiny frames and a
   moved buffer otherwise. I'd pick yes; MsgPack stays the control plane.
2. **App-chosen resource ids**, per session, with no round trips.
   I'd pick yes.
3. **Semantic SDF and backdrop commands instead of shaders**, plus one
   upstream hook in rui2. I'd pick yes.
4. **Text: Pixie on both sides over shared sealed fonts**, with a text
   backend seam in RUI (Pango | Pixie); Spleen as bootstrap; HarfBuzz via
   harfbuzzy later for complex scripts. I'd pick yes.
5. **The server decodes images** (PNG/QOI via raylib); apps move or seal
   encoded bytes. I'd pick yes.
