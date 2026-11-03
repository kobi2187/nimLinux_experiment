# SPDX-License-Identifier: GPL-2.0
## raylib bridge, remote backend for whole programs (V7b): routing at the C
## symbol level. `tools/naylib_adapt.py --remote` emits a naylib whose routed
## procs import `nxr_<Name>` instead of raylib's `<Name>`; this module defines
## those symbols (C ABI, P0's C-layout types) and turns each call into a
## draw-protocol record. Everything not routed (types, CPU image ops, queries,
## window/input) stays plain naylib, so programs like RUI don't change.
##
## The routing table is the set of `nxr_` procs below; the adapter reads the
## names from here (`nxr_` exportc), so the two can't drift.
##
## Loopback (until the render server exists, V6): the stream runs through
## rl_server in-process at `EndDrawing`, and at sync points (a call that needs
## the server's pixels now, e.g. `LoadImageFromScreen`), counted in `stats`.

import std/[monotimes, times]
import rl_types, rl_protocol, rl_server
import rl_c except Color, Vector2, Rectangle, Texture, Texture2D, RenderTexture,
  RenderTexture2D, Image, Shader

type RouteStats* = object
  frames*, records*, bytes*, blobBytes*, syncs*: int   ## totals
  lastRecords*, lastBytes*: int     ## the last complete frame
  maxRecords*, maxBytes*: int       ## the largest frame
  steadyMaxRecords*, steadyMaxBytes*: int  ## the largest after the first (a full paint)
  encodeNs*, serverNs*: int64

var
  gCmd: CmdBuf
  gServer: Session
  gNextId: uint32 = 1
  gFrameRecords, gFrameBytes: int
  gFrameStart: MonoTime
  stats*: RouteStats

proc newId(): uint32 =
  ## App-chosen ids: no round trip to create a resource.
  result = gNextId
  inc gNextId

proc flush(endOfFrame: bool) =
  ## Hand what is queued to the server (NimixOS: ringPush + one ringSubmit).
  let t0 = getMonoTime()
  gFrameRecords += gCmd.records
  gFrameBytes += gCmd.data.len
  stats.records += gCmd.records
  stats.bytes += gCmd.data.len
  for blob in gCmd.blobs: stats.blobBytes += blob.len
  gServer.execute(gCmd)
  doAssert gServer.ok, "render server rejected the stream"
  gCmd.reset()
  stats.serverNs += (getMonoTime() - t0).inNanoseconds
  if endOfFrame:
    inc stats.frames
    stats.lastRecords = gFrameRecords
    stats.lastBytes = gFrameBytes
    stats.maxRecords = max(stats.maxRecords, gFrameRecords)
    stats.maxBytes = max(stats.maxBytes, gFrameBytes)
    if stats.frames > 1:
      stats.steadyMaxRecords = max(stats.steadyMaxRecords, gFrameRecords)
      stats.steadyMaxBytes = max(stats.steadyMaxBytes, gFrameBytes)
    gFrameRecords = 0
    gFrameBytes = 0

proc sync() =
  ## The caller needs the server's state now: run the partial frame.
  inc stats.syncs
  flush(endOfFrame = false)

# ── frame ────────────────────────────────────────────────────────────────────

proc nxr_BeginDrawing() {.exportc, cdecl.} =
  gFrameStart = getMonoTime()
  gCmd.rec(opBeginFrame): gCmd.putU(uint32(stats.frames))

proc nxr_EndDrawing() {.exportc, cdecl.} =
  gCmd.rec(opEndFrame): discard
  stats.encodeNs += (getMonoTime() - gFrameStart).inNanoseconds
  flush(endOfFrame = true)

# ── shapes: one record per call, the same function on the server ────────────

proc nxr_ClearBackground(c: Color) {.exportc, cdecl.} = gCmd.rec(opClear): gCmd.putC(c)
proc nxr_DrawRectangleRec(r: Rectangle; c: Color) {.exportc, cdecl.} =
  gCmd.rec(opRect): (gCmd.putR(r); gCmd.putC(c))
proc nxr_DrawRectangleLinesEx(r: Rectangle; thick: float32; c: Color) {.exportc, cdecl.} =
  gCmd.rec(opRectLines): (gCmd.putR(r); gCmd.putF(thick); gCmd.putC(c))
proc nxr_DrawRectangleRounded(r: Rectangle; rd: float32; seg: int32; c: Color) {.exportc, cdecl.} =
  gCmd.rec(opRectRounded): (gCmd.putR(r); gCmd.putF(rd); gCmd.putI(seg); gCmd.putC(c))
proc nxr_DrawRectangleRoundedLinesEx(r: Rectangle; rd: float32; seg: int32; thick: float32;
                                     c: Color) {.exportc, cdecl.} =
  gCmd.rec(opRectRoundedLines):
    gCmd.putR(r); gCmd.putF(rd); gCmd.putI(seg); gCmd.putF(thick); gCmd.putC(c)
proc nxr_DrawLineEx(a, b: Vector2; thick: float32; c: Color) {.exportc, cdecl.} =
  gCmd.rec(opLine): (gCmd.putV(a); gCmd.putV(b); gCmd.putF(thick); gCmd.putC(c))
proc nxr_DrawCircleV(ctr: Vector2; rad: float32; c: Color) {.exportc, cdecl.} =
  gCmd.rec(opCircle): (gCmd.putV(ctr); gCmd.putF(rad); gCmd.putC(c))
proc nxr_DrawTriangle(a, b, d: Vector2; c: Color) {.exportc, cdecl.} =
  gCmd.rec(opTriangle): (gCmd.putV(a); gCmd.putV(b); gCmd.putV(d); gCmd.putC(c))
proc nxr_DrawText(text: cstring; x, y, size: int32; c: Color) {.exportc, cdecl.} =
  gCmd.rec(opText): (gCmd.putI(x); gCmd.putI(y); gCmd.putI(size); gCmd.putC(c); gCmd.putS($text))
proc nxr_DrawCircle(x, y: int32; rad: float32; c: Color) {.exportc, cdecl.} =
  gCmd.rec(opCircleI): (gCmd.putI(x); gCmd.putI(y); gCmd.putF(rad); gCmd.putC(c))
proc nxr_DrawCircleLines(x, y: int32; rad: float32; c: Color) {.exportc, cdecl.} =
  gCmd.rec(opCircleLinesI): (gCmd.putI(x); gCmd.putI(y); gCmd.putF(rad); gCmd.putC(c))

template rectI(op: Op; x, y, w, h: int32; body: untyped) =
  gCmd.rec(op):
    gCmd.putI(x); gCmd.putI(y); gCmd.putI(w); gCmd.putI(h)
    body

proc nxr_DrawRectangle(x, y, w, h: int32; c: Color) {.exportc, cdecl.} =
  rectI(opRectI, x, y, w, h): gCmd.putC(c)
proc nxr_DrawRectangleLines(x, y, w, h: int32; c: Color) {.exportc, cdecl.} =
  rectI(opRectLinesI, x, y, w, h): gCmd.putC(c)
proc nxr_DrawRectangleGradientH(x, y, w, h: int32; l, r: Color) {.exportc, cdecl.} =
  rectI(opRectGradH, x, y, w, h): (gCmd.putC(l); gCmd.putC(r))
proc nxr_DrawRectangleGradientV(x, y, w, h: int32; t, b: Color) {.exportc, cdecl.} =
  rectI(opRectGradV, x, y, w, h): (gCmd.putC(t); gCmd.putC(b))
proc nxr_DrawRing(ctr: Vector2; ri, ro, a0, a1: float32; seg: int32; c: Color) {.exportc, cdecl.} =
  gCmd.rec(opRing):
    gCmd.putV(ctr); gCmd.putF(ri); gCmd.putF(ro); gCmd.putF(a0); gCmd.putF(a1)
    gCmd.putI(seg); gCmd.putC(c)

# ── state ────────────────────────────────────────────────────────────────────

proc nxr_BeginScissorMode(x, y, w, h: int32) {.exportc, cdecl.} =
  rectI(opScissorPush, x, y, w, h): discard
proc nxr_EndScissorMode() {.exportc, cdecl.} = gCmd.rec(opScissorPop): discard
proc nxr_BeginBlendMode(mode: int32) {.exportc, cdecl.} = gCmd.rec(opBlend): gCmd.putI(mode)
proc nxr_EndBlendMode() {.exportc, cdecl.} = gCmd.rec(opBlendEnd): discard
proc nxr_rlSetBlendFactorsSeparate(a, b, c, d, e, f: int32) {.exportc, cdecl.} =
  gCmd.rec(opBlendFactors):
    for v in [a, b, c, d, e, f]: gCmd.putI(v)
proc nxr_rlDrawRenderBatchActive() {.exportc, cdecl.} = gCmd.rec(opFlush): discard
proc nxr_rlEnableScissorTest() {.exportc, cdecl.} = gCmd.rec(opScissorTest): gCmd.putU(1)
proc nxr_rlDisableScissorTest() {.exportc, cdecl.} = gCmd.rec(opScissorTest): gCmd.putU(0)
proc nxr_rlScissor(x, y, w, h: int32) {.exportc, cdecl.} =
  rectI(opScissorRaw, x, y, w, h): discard

# ── targets and textures: app-chosen ids ────────────────────────────────────

proc nxr_LoadRenderTexture(w, h: int32): RenderTexture2D {.exportc, cdecl.} =
  ## One id names the target and its colour texture (server registers both).
  let id = newId()
  gCmd.rec(opCreateTarget): (gCmd.putU(id); gCmd.putI(w); gCmd.putI(h))
  let tex = Texture(id: id, width: w, height: h, mipmaps: 1, format: PixelFormatR8G8B8A8)
  RenderTexture2D(id: id, texture: tex, depth: tex)  # depth: only so validity checks pass
proc nxr_UnloadRenderTexture(t: RenderTexture2D) {.exportc, cdecl.} =
  if t.id != 0: gCmd.rec(opDestroy): gCmd.putU(t.id)
proc nxr_BeginTextureMode(t: RenderTexture2D) {.exportc, cdecl.} =
  gCmd.rec(opBeginTarget): gCmd.putU(t.id)
proc nxr_EndTextureMode() {.exportc, cdecl.} = gCmd.rec(opEndTarget): discard

proc nxr_LoadTextureFromImage(img: Image): Texture2D {.exportc, cdecl.} =
  ## The upload: pixels travel as a blob (NimixOS: a moved or sealed buffer).
  let n = int(GetPixelDataSize(img.width, img.height, img.format))
  if img.data == nil or n <= 0 or img.mipmaps != 1: return
  let id = newId()
  gCmd.rec(opCreateTexture):
    gCmd.putU(id); gCmd.putI(img.width); gCmd.putI(img.height)
    gCmd.putI(1); gCmd.putI(img.format)
    gCmd.putBlob(toOpenArray(cast[ptr UncheckedArray[byte]](img.data), 0, n - 1))
  Texture(id: id, width: img.width, height: img.height, mipmaps: 1, format: img.format)
proc nxr_LoadTexture(path: cstring): Texture2D {.exportc, cdecl.} =
  ## Decoding is CPU work, done locally here (draw_protocol §3 has the server
  ## decode encoded bytes; that's the NimixOS route).
  let img = LoadImage(path)
  result = nxr_LoadTextureFromImage(img)
  UnloadImage(img)
proc nxr_UnloadTexture(t: Texture2D) {.exportc, cdecl.} =
  if t.id != 0: gCmd.rec(opDestroyTexture): gCmd.putU(t.id)
proc nxr_rlUnloadTexture(id: uint32) {.exportc, cdecl.} =
  if id != 0: gCmd.rec(opDestroyTexture): gCmd.putU(id)
proc nxr_SetTextureFilter(t: Texture2D; filter: int32) {.exportc, cdecl.} =
  gCmd.rec(opTexFilter): (gCmd.putU(t.id); gCmd.putI(filter))
proc nxr_SetTextureWrap(t: Texture2D; wrap: int32) {.exportc, cdecl.} =
  gCmd.rec(opTexWrap): (gCmd.putU(t.id); gCmd.putI(wrap))
proc nxr_DrawTextureRec(t: Texture2D; src: Rectangle; pos: Vector2; tint: Color) {.exportc, cdecl.} =
  gCmd.rec(opDrawTexture): (gCmd.putU(t.id); gCmd.putR(src); gCmd.putV(pos); gCmd.putC(tint))
proc nxr_DrawTextureV(t: Texture2D; pos: Vector2; tint: Color) {.exportc, cdecl.} =
  gCmd.rec(opTextureV): (gCmd.putU(t.id); gCmd.putV(pos); gCmd.putC(tint))
proc nxr_DrawTexturePro(t: Texture2D; src, dst: Rectangle; origin: Vector2; rot: float32;
                        tint: Color) {.exportc, cdecl.} =
  gCmd.rec(opTexturePro):
    gCmd.putU(t.id); gCmd.putR(src); gCmd.putR(dst); gCmd.putV(origin); gCmd.putF(rot)
    gCmd.putC(tint)

# ── refused locally: no raw GPU objects or shaders cross the boundary ───────

proc nxr_rlLoadFramebuffer(): uint32 {.exportc, cdecl.} =
  ## 0 = "not available": RUI then asks for a target (`loadRenderTexture`).
  0
proc nxr_LoadShaderFromMemory(vs, fs: cstring): Shader {.exportc, cdecl.} =
  ## No GLSL on the software renderer (rlsw gives id 0 too): RUI falls back.
  ## Its SDF/backdrop work becomes semantic commands later (draw_protocol §3).
  Shader()
proc nxr_BeginShaderMode(s: Shader) {.exportc, cdecl.} =
  doAssert false, "remote: shaders are not routed (isShaderValid is false)"
proc nxr_EndShaderMode() {.exportc, cdecl.} = discard

# ── sync points: need the server's pixels now ───────────────────────────────

proc nxr_LoadImageFromScreen(): Image {.exportc, cdecl.} =
  ## Loopback: run the partial frame, then read back. NimixOS: SNAPSHOT into
  ## a texture (draw_protocol §3), with no pixel readback at all.
  sync()
  LoadImageFromScreen()
