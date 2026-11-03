# SPDX-License-Identifier: GPL-2.0
## raylib bridge — the value types RUI and raylib programs use, with naylib's
## names and raylib 6.2's C layouts (passed by value across the C ABI).

type
  Color* {.bycopy.} = object
    r*, g*, b*, a*: uint8
  Vector2* {.bycopy.} = object
    x*, y*: float32
  Rectangle* {.bycopy.} = object
    x*, y*, width*, height*: float32
  Texture* {.bycopy.} = object
    id*: uint32                 ## remote backend: an app-chosen session id
    width*, height*, mipmaps*, format*: int32
  Texture2D* = Texture
  RenderTexture* {.bycopy.} = object
    id*: uint32
    texture*, depth*: Texture
  RenderTexture2D* = RenderTexture

const
  PixelFormatR8G8B8A8* = 7'i32
  LightGray* = Color(r: 200, g: 200, b: 200, a: 255)
  Gray*      = Color(r: 130, g: 130, b: 130, a: 255)
  DarkGray*  = Color(r: 80, g: 80, b: 80, a: 255)
  Red*       = Color(r: 230, g: 41, b: 55, a: 255)
  Orange*    = Color(r: 255, g: 161, b: 0, a: 255)
  Blue*      = Color(r: 0, g: 121, b: 241, a: 255)
  DarkGreen* = Color(r: 0, g: 117, b: 44, a: 255)
  Black*     = Color(r: 0, g: 0, b: 0, a: 255)
  White*     = Color(r: 255, g: 255, b: 255, a: 255)
  RayWhite*  = Color(r: 245, g: 245, b: 245, a: 255)
