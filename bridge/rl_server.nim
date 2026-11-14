# SPDX-License-Identifier: GPL-2.0
## The render server's command executor: replays a stream of records through
## raylib. Untrusted input: every read is bounded by its record's length, ids
## are looked up in this session's tables, and a bad record ends the stream.
##
## Ids are app-chosen and per session (draw_protocol §4). Two tables:
##   targets[id]   render targets (CREATE_TARGET)
##   textures[id]  anything drawable: uploaded textures, and each target's
##                 colour attachment, registered under the target's own id.
## Destroys are idempotent: an app (RUI) may free a target's texture and then
## the target; both name only this session's ids, so tolerating it is safe.

import rl_types, rl_c, rl_protocol

type
  TexEntry = object
    tex: Texture2D
    live: bool
    ofTarget: bool          ## a target's colour attachment: freed with the target

  Session* = object
    targets: seq[RenderTexture2D]   ## index = app id (0 unused)
    textures: seq[TexEntry]
    ok*: bool                       ## false after a malformed stream

proc target(s: Session; id: uint32): ptr RenderTexture2D =
  if id == 0 or int(id) >= s.targets.len or s.targets[id].id == 0: return nil
  unsafeAddr s.targets[id]

proc texture(s: Session; id: uint32): ptr Texture2D =
  if id == 0 or int(id) >= s.textures.len or not s.textures[id].live: return nil
  unsafeAddr s.textures[id].tex

proc slot[T](tab: var seq[T]; id: uint32): bool =
  ## Make room for a new id; false for 0 or an id beyond a sane bound.
  if id == 0 or id > 1_000_000: return false
  if int(id) >= tab.len: tab.setLen(int(id) + 1)
  true

proc createTarget(s: var Session; b: CmdBuf; r: var Reader): bool =
  let id = get[uint32](b, r)
  let w = get[int32](b, r)
  let h = get[int32](b, r)
  if r.bad or w <= 0 or h <= 0 or not s.targets.slot(id) or not s.textures.slot(id): return false
  if s.targets[id].id != 0: return false            # id already in use
  s.targets[id] = LoadRenderTexture(w, h)
  s.textures[id] = TexEntry(tex: s.targets[id].texture, live: true, ofTarget: true)
  true

proc destroyTarget(s: var Session; id: uint32): bool =
  let t = s.target(id)
  if t == nil: return true                          # idempotent
  UnloadRenderTexture(t[])
  t[].id = 0
  s.textures[id].live = false
  true

proc createTexture(s: var Session; b: CmdBuf; r: var Reader): bool =
  ## Pixels arrive as a blob (on NimixOS: a moved or sealed buffer).
  let id = get[uint32](b, r)
  let w = get[int32](b, r)
  let h = get[int32](b, r)
  let mips = get[int32](b, r)
  let fmt = get[int32](b, r)
  let blob = get[uint32](b, r)
  if r.bad or w <= 0 or h <= 0 or mips != 1 or fmt < 1 or fmt > 10: return false
  if int(blob) >= b.blobs.len or not s.textures.slot(id) or s.textures[id].live: return false
  let need = int(GetPixelDataSize(w, h, fmt))
  if need <= 0 or b.blobs[blob].len != need: return false
  let img = Image(data: unsafeAddr b.blobs[blob][0], width: w, height: h, mipmaps: 1, format: fmt)
  s.textures[id] = TexEntry(tex: LoadTextureFromImage(img), live: true)
  true

proc destroyTexture(s: var Session; id: uint32): bool =
  if s.texture(id) == nil: return true              # idempotent
  if not s.textures[id].ofTarget: UnloadTexture(s.textures[id].tex)
  s.textures[id].live = false
  true

template withTex(s: Session; b: CmdBuf; r: var Reader; t, body: untyped) =
  let t = s.texture(get[uint32](b, r))
  if t == nil: return false
  body

proc execShapes(s: var Session; b: CmdBuf; op: Op; r: var Reader) =
  ## Records that only draw (no ids). Args are read in call order.
  template f: float32 = get[float32](b, r)
  template i: int32 = get[int32](b, r)
  template c: Color = get[Color](b, r)
  template v: Vector2 = get[Vector2](b, r)
  template rc: Rectangle = get[Rectangle](b, r)
  case op
  of opClear: ClearBackground(c)
  of opRect: (let a = rc; DrawRectangleRec(a, c))
  of opRectLines: (let a = rc; let t = f; DrawRectangleLinesEx(a, t, c))
  of opRectRounded: (let a = rc; let rd = f; let sg = i; DrawRectangleRounded(a, rd, sg, c))
  of opLine: (let a = v; let z = v; let t = f; DrawLineEx(a, z, t, c))
  of opCircle: (let a = v; let rd = f; DrawCircleV(a, rd, c))
  of opTriangle: (let p0 = v; let p1 = v; let p2 = v; DrawTriangle(p0, p1, p2, c))
  of opText:
    let x = i; let y = i; let sz = i; let col = c
    let text = getS(b, r)
    if not r.bad: DrawText(text.cstring, x, y, sz, col)
  of opCircleI: (let x = i; let y = i; let rd = f; DrawCircle(x, y, rd, c))
  of opCircleLinesI: (let x = i; let y = i; let rd = f; DrawCircleLines(x, y, rd, c))
  of opRectI: (let x = i; let y = i; let w = i; let h = i; DrawRectangle(x, y, w, h, c))
  of opRectGradH:
    let x = i; let y = i; let w = i; let h = i; let c0 = c
    DrawRectangleGradientH(x, y, w, h, c0, c)
  of opRectGradV:
    let x = i; let y = i; let w = i; let h = i; let c0 = c
    DrawRectangleGradientV(x, y, w, h, c0, c)
  of opRectLinesI: (let x = i; let y = i; let w = i; let h = i; DrawRectangleLines(x, y, w, h, c))
  of opRectRoundedLines:
    let a = rc; let rd = f; let sg = i; let t = f
    DrawRectangleRoundedLinesEx(a, rd, sg, t, c)
  of opRing:
    let ctr = v; let ri = f; let ro = f; let a0 = f; let a1 = f; let sg = i
    DrawRing(ctr, ri, ro, a0, a1, sg, c)
  of opScissorPush: (let x = i; let y = i; let w = i; let h = i; BeginScissorMode(x, y, w, h))
  of opScissorPop: EndScissorMode()
  of opBlend: BeginBlendMode(i)
  of opBlendEnd: EndBlendMode()
  of opBlendFactors:
    let a = i; let bb = i; let cc = i; let d = i; let e = i
    rlSetBlendFactorsSeparate(a, bb, cc, d, e, i)
  of opFlush: rlDrawRenderBatchActive()
  of opScissorTest: (if get[uint32](b, r) != 0: rlEnableScissorTest() else: rlDisableScissorTest())
  of opScissorRaw: (let x = i; let y = i; let w = i; rlScissor(x, y, w, i))
  else: discard

proc exec(s: var Session; b: CmdBuf; op: Op; r: var Reader): bool =
  ## One record's effect. False: malformed, or an id this session doesn't own.
  case op
  of opBeginFrame: (discard get[uint32](b, r); BeginDrawing())
  of opEndFrame: EndDrawing()
  of opCreateTarget: return s.createTarget(b, r)
  of opDestroy: return s.destroyTarget(get[uint32](b, r))
  of opBeginTarget:
    let t = s.target(get[uint32](b, r))
    if t == nil: return false
    BeginTextureMode(t[])
  of opEndTarget: EndTextureMode()
  of opCreateTexture: return s.createTexture(b, r)
  of opDestroyTexture: return s.destroyTexture(get[uint32](b, r))
  of opTexFilter:
    s.withTex(b, r, t):
      SetTextureFilter(t[], get[int32](b, r))
  of opTexWrap:
    s.withTex(b, r, t):
      SetTextureWrap(t[], get[int32](b, r))
  of opDrawTexture:
    s.withTex(b, r, t):
      let src = get[Rectangle](b, r); let pos = get[Vector2](b, r)
      DrawTextureRec(t[], src, pos, get[Color](b, r))
  of opTextureV:
    s.withTex(b, r, t):
      let pos = get[Vector2](b, r)
      DrawTextureV(t[], pos, get[Color](b, r))
  of opTexturePro:
    s.withTex(b, r, t):
      let src = get[Rectangle](b, r); let dst = get[Rectangle](b, r)
      let org = get[Vector2](b, r); let rot = get[float32](b, r)
      DrawTexturePro(t[], src, dst, org, rot, get[Color](b, r))
  else: s.execShapes(b, op, r)
  not r.bad

proc execute*(s: var Session; b: CmdBuf) =
  ## Run a stream of records (a frame, or the part of one before a sync
  ## point). Unknown ops are skipped by their length.
  var p = 0
  s.ok = true
  while p + 4 <= b.data.len:
    let op = b.data[p]
    let len = int(b.data[p + 2]) or (int(b.data[p + 3]) shl 8)
    if len < 4 or p + len > b.data.len: (s.ok = false; return)
    if op >= uint8(ord(Op.low)) and op <= uint8(ord(Op.high)):
      var r = Reader(p: p + 4, limit: p + len)
      if not s.exec(b, Op(op), r): (s.ok = false; return)
    p += len
