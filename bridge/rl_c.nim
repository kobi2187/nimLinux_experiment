# SPDX-License-Identifier: GPL-2.0
## raylib bridge — the C side: raylib 6.2 (vendor/raylib) built headless with
## the memory platform and the rlsw software renderer. Used by the `direct`
## backend and by the render server (the `remote` backend's decoder).

import rl_types

const RlSrc = currentSourcePath()[0 ..< currentSourcePath().len - "bridge/rl_c.nim".len] & "vendor/raylib/src/"
{.passC: "-DPLATFORM_MEMORY -DGRAPHICS_API_OPENGL_SOFTWARE -DSUPPORT_MODULE_RAUDIO=0 -I" & RlSrc.}
{.compile: RlSrc & "rcore.c".}
{.compile: RlSrc & "rshapes.c".}
{.compile: RlSrc & "rtextures.c".}
{.compile: RlSrc & "rtext.c".}
{.compile: RlSrc & "rmodels.c".}
{.passL: "-lm".}

{.push cdecl, importc.}
proc InitWindow*(w, h: int32; title: cstring)
proc CloseWindow*()
proc SetTraceLogLevel*(level: int32)
proc BeginDrawing*()
proc EndDrawing*()
proc ClearBackground*(c: Color)
proc DrawRectangleRec*(r: Rectangle; c: Color)
proc DrawRectangleLinesEx*(r: Rectangle; thick: float32; c: Color)
proc DrawRectangleRounded*(r: Rectangle; roundness: float32; segments: int32; c: Color)
proc DrawLineEx*(a, b: Vector2; thick: float32; c: Color)
proc DrawCircleV*(center: Vector2; radius: float32; c: Color)
proc DrawTriangle*(a, b, c: Vector2; col: Color)
proc DrawText*(text: cstring; x, y, size: int32; c: Color)
proc LoadRenderTexture*(w, h: int32): RenderTexture2D
proc UnloadRenderTexture*(t: RenderTexture2D)
proc BeginTextureMode*(t: RenderTexture2D)
proc EndTextureMode*()
proc DrawTextureRec*(t: Texture2D; src: Rectangle; pos: Vector2; tint: Color)
proc BeginScissorMode*(x, y, w, h: int32)
proc EndScissorMode*()
{.pop.}

type CImage* {.bycopy.} = object
  data*: pointer
  width*, height*, mipmaps*, format*: int32
proc LoadImageFromScreen*(): CImage {.cdecl, importc.}
proc ExportImage*(img: CImage; path: cstring): bool {.cdecl, importc.}
proc UnloadImage*(img: CImage) {.cdecl, importc.}
