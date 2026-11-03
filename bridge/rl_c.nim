# SPDX-License-Identifier: GPL-2.0
## raylib bridge — the C side: raylib 6.2 (vendor/raylib) built headless with
## the memory platform and the rlsw software renderer. Used by the `direct`
## backend and by the render server (the `remote` backend's decoder).

import rl_types

const RlSrc = currentSourcePath()[0 ..< currentSourcePath().len - "bridge/rl_c.nim".len] & "vendor/raylib/src/"
{.passC: "-DPLATFORM_MEMORY -DGRAPHICS_API_OPENGL_SOFTWARE -DSUPPORT_MODULE_RAUDIO=0 -I" & RlSrc.}
{.passC: "-DRLSW_MAX_FRAMEBUFFERS=512 -DRLSW_MAX_TEXTURES=2048".}  # RUI: a target per widget
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
# V7b: the rest of what RUI draws with (server side of the remote backend).
proc DrawCircle*(cx, cy: int32; radius: float32; c: Color)
proc DrawCircleLines*(cx, cy: int32; radius: float32; c: Color)
proc DrawRectangle*(x, y, w, h: int32; c: Color)
proc DrawRectangleGradientH*(x, y, w, h: int32; left, right: Color)
proc DrawRectangleGradientV*(x, y, w, h: int32; top, bottom: Color)
proc DrawRectangleLines*(x, y, w, h: int32; c: Color)
proc DrawRectangleRoundedLinesEx*(r: Rectangle; roundness: float32; segments: int32; thick: float32; c: Color)
proc DrawRing*(center: Vector2; inner, outer, a0, a1: float32; segments: int32; c: Color)
proc DrawTexturePro*(t: Texture2D; src, dst: Rectangle; origin: Vector2; rotation: float32; tint: Color)
proc DrawTextureV*(t: Texture2D; pos: Vector2; tint: Color)
proc LoadTextureFromImage*(img: Image): Texture2D
proc UnloadTexture*(t: Texture2D)
proc SetTextureFilter*(t: Texture2D; filter: int32)
proc SetTextureWrap*(t: Texture2D; wrap: int32)
proc LoadImage*(path: cstring): Image
proc GetPixelDataSize*(w, h, format: int32): int32
proc BeginBlendMode*(mode: int32)
proc EndBlendMode*()
proc rlSetBlendFactorsSeparate*(srcRGB, dstRGB, srcA, dstA, eqRGB, eqA: int32)
proc rlDrawRenderBatchActive*()
proc rlEnableScissorTest*()
proc rlDisableScissorTest*()
proc rlScissor*(x, y, w, h: int32)
{.pop.}

type CImage* = Image
proc LoadImageFromScreen*(): CImage {.cdecl, importc.}
proc ExportImage*(img: CImage; path: cstring): bool {.cdecl, importc.}
proc UnloadImage*(img: CImage) {.cdecl, importc.}
