/* SPDX-License-Identifier: GPL-2.0
 * The rldemo scene: a fixed picture, drawn with plain raylib C calls. Shared by the
 * NimixOS program (rldemo.c) and the host reference renderer (tests/v5/rldemo_host.c),
 * so the two can be compared pixel for pixel. No animation, no time: a pure function. */
#pragma once
#include "raylib.h"

#define RLDEMO_W 640
#define RLDEMO_H 400

static inline void rldemo_draw(void) {
    ClearBackground(RAYWHITE);
    DrawRectangle(20, 20, 200, 120, SKYBLUE);
    DrawRectangleLines(20, 20, 200, 120, DARKBLUE);
    DrawRectangleGradientV(240, 20, 160, 120, ORANGE, RED);
    DrawCircle(120, 260, 70, GREEN);
    DrawCircleLines(120, 260, 70, DARKGREEN);
    DrawRectangleRounded((Rectangle){ 240, 170, 200, 110 }, 0.3f, 8, PURPLE);
    DrawTriangle((Vector2){ 520, 40 }, (Vector2){ 440, 160 }, (Vector2){ 600, 160 }, MAROON);   /* counter-clockwise: raylib culls the other winding */
    DrawLineEx((Vector2){ 20, 360 }, (Vector2){ 620, 330 }, 3.0f, BLACK);
    DrawRing((Vector2){ 540, 260 }, 30.0f, 60.0f, 0.0f, 270.0f, 24, GOLD);
    DrawText("NimixOS + raylib", 30, 160, 20, DARKGRAY);
    DrawText("rlsw software renderer", 30, 182, 10, GRAY);
}
