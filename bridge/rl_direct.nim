# SPDX-License-Identifier: GPL-2.0
## raylib bridge, `direct` backend: naylib-named inline forwards to raylib.
## Zero cost: each call compiles to the C call it wraps.

import rl_types, rl_c
export rl_types

{.push inline.}
proc initWindow*(w, h: int32; title: string) =
  SetTraceLogLevel(4); InitWindow(w, h, title.cstring)
proc closeWindow*() = CloseWindow()
proc beginDrawing*() = BeginDrawing()
proc endDrawing*() = EndDrawing()
proc clearBackground*(c: Color) = ClearBackground(c)
proc drawRectangle*(r: Rectangle; c: Color) = DrawRectangleRec(r, c)
proc drawRectangleLines*(r: Rectangle; thick: float32; c: Color) = DrawRectangleLinesEx(r, thick, c)
proc drawRectangleRounded*(r: Rectangle; roundness: float32; segments: int32; c: Color) =
  DrawRectangleRounded(r, roundness, segments, c)
proc drawLine*(a, b: Vector2; thick: float32; c: Color) = DrawLineEx(a, b, thick, c)
proc drawCircle*(center: Vector2; radius: float32; c: Color) = DrawCircleV(center, radius, c)
proc drawTriangle*(a, b, c: Vector2; col: Color) = DrawTriangle(a, b, c, col)
proc drawText*(text: string; x, y, size: int32; c: Color) = DrawText(text.cstring, x, y, size, c)
proc loadRenderTexture*(w, h: int32): RenderTexture2D = LoadRenderTexture(w, h)
proc unloadRenderTexture*(t: RenderTexture2D) = UnloadRenderTexture(t)
proc beginTextureMode*(t: RenderTexture2D) = BeginTextureMode(t)
proc endTextureMode*() = EndTextureMode()
proc drawTexture*(t: Texture2D; src: Rectangle; pos: Vector2; tint: Color) = DrawTextureRec(t, src, pos, tint)
proc beginScissorMode*(x, y, w, h: int32) = BeginScissorMode(x, y, w, h)
proc endScissorMode*() = EndScissorMode()
{.pop.}
