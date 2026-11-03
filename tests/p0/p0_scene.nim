# SPDX-License-Identifier: GPL-2.0
## P0 (BACKLOG): one RUI-shaped screen through the raylib bridge. Built twice:
## direct (in-process raylib) and -d:rlRemote (commands → loopback server).
## RUI's model: every widget paints into its own cached render texture; a
## parent composites its children; only dirty widgets repaint.
##   p0_scene <out.raw> <frames>   →  stdout: one "stat key=value" line per stat

import std/[os, strutils, monotimes, times]
import ../../bridge/raylib
import ../../bridge/rl_c except Color, Vector2, Rectangle, Texture, Texture2D, RenderTexture, RenderTexture2D
when defined(rlRemote):
  import ../../bridge/rl_remote

const W = 640'i32
const H = 400'i32

type Widget = object
  rect: Rectangle               ## position in its parent
  tex: RenderTexture2D
  label: string
  hot: bool

proc rr(x, y, w, h: float32): Rectangle = Rectangle(x: x, y: y, width: w, height: h)
proc v(x, y: float32): Vector2 = Vector2(x: x, y: y)

proc paintButton(w: var Widget) =
  beginTextureMode(w.tex)
  clearBackground(Color(r: 0, g: 0, b: 0, a: 0))
  let fill = if w.hot: Orange else: Blue
  drawRectangleRounded(rr(1, 1, w.rect.width - 2, w.rect.height - 2), 0.35, 8, fill)
  drawRectangleLines(rr(0, 0, w.rect.width, w.rect.height), 1, DarkGray)
  drawText(w.label, 12, 8, 20, White)
  endTextureMode()

proc paintList(t: RenderTexture2D; rows: int) =
  beginTextureMode(t)
  clearBackground(RayWhite)
  for i in 0 ..< rows:
    let y = float32(i * 18)
    if i mod 2 == 0: drawRectangle(rr(0, y, 280, 18), LightGray)
    drawText("row " & $i & "  item value", 6, int32(y) + 4, 10, Black)
    drawLine(v(0, y + 17), v(280, y + 17), 1, Gray)
  endTextureMode()

proc paintControls(t: RenderTexture2D; level: float32) =
  beginTextureMode(t)
  clearBackground(RayWhite)
  drawRectangleLines(rr(10, 10, 20, 20), 2, DarkGray)                  # checkbox
  drawTriangle(v(13, 20), v(19, 27), v(27, 13), DarkGreen)              # check mark
  drawText("enabled", 38, 14, 10, Black)
  drawLine(v(10, 60), v(250, 60), 3, Gray)                              # slider
  drawCircle(v(10 + 240 * level, 60), 8, Red)
  endTextureMode()

proc blit(t: RenderTexture2D; at: Rectangle) =
  ## Composite a cached child texture into the current target (RUI's blit).
  drawTexture(t.texture, rr(0, 0, at.width, -at.height), v(at.x, at.y), White)

proc main() =
  let outPath = paramStr(1)
  let frames = parseInt(paramStr(2))
  initWindow(W, H, "p0")
  var buttons = @[
    Widget(rect: rr(20, 60, 120, 36), label: "Open"),
    Widget(rect: rr(150, 60, 120, 36), label: "Save"),
    Widget(rect: rr(280, 60, 120, 36), label: "Quit")]
  for b in buttons.mitems: b.tex = loadRenderTexture(int32(b.rect.width), int32(b.rect.height))
  let listR = rr(20, 110, 280, 288)
  let ctrlR = rr(320, 110, 300, 100)
  let list = loadRenderTexture(int32(listR.width), int32(listR.height))
  let ctrls = loadRenderTexture(int32(ctrlR.width), int32(ctrlR.height))
  let root = loadRenderTexture(W, H)

  var t0 = getMonoTime()
  var firstNs, steadyNs: int64
  for f in 0 ..< frames:
    let full = f == 0
    # Dirty widgets repaint (frame 0: all; then one button toggles "hover").
    if full:
      for b in buttons.mitems: b.paintButton()
      paintList(list, 16)
      paintControls(ctrls, 0.6)
    else:
      buttons[1].hot = not buttons[1].hot
      buttons[1].paintButton()
    # The parent recomposites; the window shows the root.
    beginTextureMode(root)
    clearBackground(RayWhite)
    drawRectangle(rr(0, 0, float32(W), 40), DarkGray)                   # title bar
    drawText("P0 - bridge loopback", 12, 12, 20, White)
    for b in buttons: blit(b.tex, b.rect)
    blit(list, listR)
    blit(ctrls, ctrlR)
    endTextureMode()
    beginDrawing()
    blit(root, rr(0, 0, float32(W), float32(H)))
    endDrawing()
    let t1 = getMonoTime()
    if full:
      firstNs = (t1 - t0).inNanoseconds
      when defined(rlRemote):
        echo "stat full_records=", stats.records
        echo "stat full_bytes=", stats.bytes
        stats = BridgeStats()                    # steady state from here on
    else: steadyNs += (t1 - t0).inNanoseconds
    t0 = t1

  let img = LoadImageFromScreen()
  var f = open(outPath, fmWrite)
  discard f.writeBuffer(img.data, int(img.width * img.height * 4))
  f.close()
  echo "stat full_frame_us=", firstNs div 1000
  echo "stat steady_frame_us=", steadyNs div 1000 div max(1, frames - 1)
  when defined(rlRemote):
    echo "stat steady_records_per_frame=", stats.records div stats.frames
    echo "stat steady_bytes_per_frame=", stats.bytes div stats.frames
    echo "stat steady_encode_us=", stats.encodeNs div 1000 div stats.frames
    echo "stat steady_server_us=", stats.serverNs div 1000 div stats.frames

main()
