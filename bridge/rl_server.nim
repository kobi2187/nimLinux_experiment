# SPDX-License-Identifier: GPL-2.0
## The render server's command executor: replays a frame's records through
## raylib. Untrusted input: every record's length is checked, ids are
## looked up in this session's table, and a bad record ends the frame.

import rl_types, rl_c, rl_protocol

type
  Session* = object
    targets: seq[RenderTexture2D]   ## index = app id (0 unused)
    ok*: bool                       ## false after a malformed frame

proc target(s: Session; id: uint32): ptr RenderTexture2D =
  if id == 0 or int(id) >= s.targets.len or s.targets[id].id == 0: return nil
  unsafeAddr s.targets[id]

proc exec(s: var Session; b: CmdBuf; op: Op; r: var Reader): bool =
  ## One record's effect. False: unknown id (the frame stops there).
  case op
  of opBeginFrame: (discard get[uint32](b, r); BeginDrawing())
  of opEndFrame: EndDrawing()
  of opCreateTarget:
    let id = get[uint32](b, r)
    let w = get[int32](b, r)
    let h = get[int32](b, r)
    if int(id) >= s.targets.len: s.targets.setLen(int(id) + 1)
    s.targets[id] = LoadRenderTexture(w, h)
  of opDestroy:
    let t = s.target(get[uint32](b, r))
    if t == nil: return false
    UnloadRenderTexture(t[]); t[].id = 0
  of opBeginTarget:
    let t = s.target(get[uint32](b, r))
    if t == nil: return false
    BeginTextureMode(t[])
  of opEndTarget: EndTextureMode()
  of opScissorPush:
    let x = get[int32](b, r); let y = get[int32](b, r)
    let w = get[int32](b, r); let h = get[int32](b, r)
    BeginScissorMode(x, y, w, h)
  of opScissorPop: EndScissorMode()
  of opClear: ClearBackground(get[Color](b, r))
  of opRect:
    let rc = get[Rectangle](b, r); DrawRectangleRec(rc, get[Color](b, r))
  of opRectLines:
    let rc = get[Rectangle](b, r); let th = get[float32](b, r)
    DrawRectangleLinesEx(rc, th, get[Color](b, r))
  of opRectRounded:
    let rc = get[Rectangle](b, r); let rd = get[float32](b, r)
    let sg = get[int32](b, r); DrawRectangleRounded(rc, rd, sg, get[Color](b, r))
  of opLine:
    let a = get[Vector2](b, r); let c = get[Vector2](b, r)
    let th = get[float32](b, r); DrawLineEx(a, c, th, get[Color](b, r))
  of opCircle:
    let ctr = get[Vector2](b, r); let rad = get[float32](b, r)
    DrawCircleV(ctr, rad, get[Color](b, r))
  of opTriangle:
    let p0 = get[Vector2](b, r); let p1 = get[Vector2](b, r)
    let p2 = get[Vector2](b, r); DrawTriangle(p0, p1, p2, get[Color](b, r))
  of opText:
    let x = get[int32](b, r); let y = get[int32](b, r)
    let sz = get[int32](b, r); let c = get[Color](b, r)
    DrawText(getS(b, r).cstring, x, y, sz, c)
  of opDrawTexture:
    let t = s.target(get[uint32](b, r))
    if t == nil: return false
    let src = get[Rectangle](b, r); let pos = get[Vector2](b, r)
    DrawTextureRec(t[].texture, src, pos, get[Color](b, r))
  true

proc execute*(s: var Session; b: CmdBuf) =
  ## Run one frame's command stream. Lengths are validated before a record
  ## is read; unknown ops are skipped by their length.
  var p = 0
  s.ok = true
  while p + 4 <= b.data.len:
    let op = b.data[p]
    let len = int(b.data[p + 2]) or (int(b.data[p + 3]) shl 8)
    if len < 4 or p + len > b.data.len: (s.ok = false; return)
    if op >= uint8(ord(Op.low)) and op <= uint8(ord(Op.high)):
      var r = Reader(p: p + 4)
      if not s.exec(b, Op(op), r) or r.p > p + len: (s.ok = false; return)
    p += len
