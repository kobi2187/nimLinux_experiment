# SPDX-License-Identifier: GPL-2.0
## raylib bridge, `remote` backend: the same API, each draw op appended to
## the frame's command stream. P0 runs the render server in-process
## (loopback): endDrawing hands the stream to rl_server, where NimixOS will
## ringSubmit it to the render server's session.

import std/[monotimes, times]
import rl_types, rl_protocol, rl_server
import rl_c except Color, Vector2, Rectangle, Texture, Texture2D, RenderTexture, RenderTexture2D
export rl_types

type BridgeStats* = object
  frames*, records*, bytes*: int     ## totals over all frames
  encodeNs*, serverNs*: int64        ## time in app-side encoding vs server execution

var
  gCmd: CmdBuf
  gServer: Session
  gNextId: uint32 = 1
  gFrameStart: MonoTime
  stats*: BridgeStats

proc initWindow*(w, h: int32; title: string) =
  ## Control plane in NimixOS (app_server); the loopback server owns the window.
  SetTraceLogLevel(4); InitWindow(w, h, title.cstring)
proc closeWindow*() = CloseWindow()

proc beginDrawing*() =
  gFrameStart = getMonoTime()
  gCmd.rec(opBeginFrame): gCmd.putU(uint32(stats.frames))

proc endDrawing*() =
  gCmd.rec(opEndFrame): discard
  let t0 = getMonoTime()
  stats.encodeNs += (t0 - gFrameStart).inNanoseconds
  stats.records += gCmd.records
  stats.bytes += gCmd.data.len
  inc stats.frames
  gServer.execute(gCmd)                       # NimixOS: ringPush + ringSubmit
  doAssert gServer.ok, "render server rejected the frame"
  stats.serverNs += (getMonoTime() - t0).inNanoseconds
  gCmd.reset()

proc clearBackground*(c: Color) = gCmd.rec(opClear): gCmd.putC(c)
proc drawRectangle*(r: Rectangle; c: Color) =
  gCmd.rec(opRect): (gCmd.putR(r); gCmd.putC(c))
proc drawRectangleLines*(r: Rectangle; thick: float32; c: Color) =
  gCmd.rec(opRectLines): (gCmd.putR(r); gCmd.putF(thick); gCmd.putC(c))
proc drawRectangleRounded*(r: Rectangle; roundness: float32; segments: int32; c: Color) =
  gCmd.rec(opRectRounded): (gCmd.putR(r); gCmd.putF(roundness); gCmd.putI(segments); gCmd.putC(c))
proc drawLine*(a, b: Vector2; thick: float32; c: Color) =
  gCmd.rec(opLine): (gCmd.putV(a); gCmd.putV(b); gCmd.putF(thick); gCmd.putC(c))
proc drawCircle*(center: Vector2; radius: float32; c: Color) =
  gCmd.rec(opCircle): (gCmd.putV(center); gCmd.putF(radius); gCmd.putC(c))
proc drawTriangle*(a, b, c: Vector2; col: Color) =
  gCmd.rec(opTriangle): (gCmd.putV(a); gCmd.putV(b); gCmd.putV(c); gCmd.putC(col))
proc drawText*(text: string; x, y, size: int32; c: Color) =
  gCmd.rec(opText): (gCmd.putI(x); gCmd.putI(y); gCmd.putI(size); gCmd.putC(c); gCmd.putS(text))

proc loadRenderTexture*(w, h: int32): RenderTexture2D =
  ## The app picks the id: no round trip.
  let id = gNextId
  inc gNextId
  gCmd.rec(opCreateTarget): (gCmd.putU(id); gCmd.putI(w); gCmd.putI(h))
  let tex = Texture(id: id, width: w, height: h, mipmaps: 1, format: PixelFormatR8G8B8A8)
  RenderTexture2D(id: id, texture: tex)
proc unloadRenderTexture*(t: RenderTexture2D) = gCmd.rec(opDestroy): gCmd.putU(t.id)
proc beginTextureMode*(t: RenderTexture2D) = gCmd.rec(opBeginTarget): gCmd.putU(t.id)
proc endTextureMode*() = gCmd.rec(opEndTarget): discard
proc drawTexture*(t: Texture2D; src: Rectangle; pos: Vector2; tint: Color) =
  gCmd.rec(opDrawTexture): (gCmd.putU(t.id); gCmd.putR(src); gCmd.putV(pos); gCmd.putC(tint))
proc beginScissorMode*(x, y, w, h: int32) =
  gCmd.rec(opScissorPush): (gCmd.putI(x); gCmd.putI(y); gCmd.putI(w); gCmd.putI(h))
proc endScissorMode*() = gCmd.rec(opScissorPop): discard
