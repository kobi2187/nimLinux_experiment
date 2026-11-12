/* SPDX-License-Identifier: GPL-2.0
 * rlmouse — pointer input into raylib on NimixOS (V5e).
 * A 20x20 square follows the pointer (a mouse moves it, a tablet sets it): BLUE normally,
 * RED while the left button is down, GREEN while the right one is. Every change is
 * printed so a host test can pace itself on it:
 *   rlmouse: pos X Y     (window coordinates)   rlmouse: left down|up   rlmouse: right down|up
 *   rlmouse: wheel N
 * Q (or Esc) quits. */
#include <stdio.h>
#include "raylib.h"

int main(void) {
    InitWindow(640, 400, "rlmouse");
    if (!IsWindowReady()) { printf("rlmouse: FAIL window\n"); return 1; }
    SetTargetFPS(30);
    int lx = -1, ly = -1;
    printf("rlmouse: ready\n");
    while (!WindowShouldClose()) {
        Vector2 p = GetMousePosition();
        int x = (int)p.x, y = (int)p.y;
        if (x != lx || y != ly) { printf("rlmouse: pos %d %d\n", x, y); lx = x; ly = y; }
        if (IsMouseButtonPressed(MOUSE_BUTTON_LEFT))  printf("rlmouse: left down\n");
        if (IsMouseButtonReleased(MOUSE_BUTTON_LEFT)) printf("rlmouse: left up\n");
        if (IsMouseButtonPressed(MOUSE_BUTTON_RIGHT))  printf("rlmouse: right down\n");
        if (IsMouseButtonReleased(MOUSE_BUTTON_RIGHT)) printf("rlmouse: right up\n");
        float w = GetMouseWheelMove();
        if (w != 0.0f) printf("rlmouse: wheel %d\n", (int)w);
        if (IsKeyPressed(KEY_Q)) break;

        Color c = IsMouseButtonDown(MOUSE_BUTTON_LEFT) ? RED : IsMouseButtonDown(MOUSE_BUTTON_RIGHT) ? GREEN : BLUE;
        BeginDrawing();
        ClearBackground(RAYWHITE);
        DrawRectangle(x - 10, y - 10, 20, 20, c);
        DrawText("rlmouse: move, click, scroll; Q quits", 20, 20, 20, DARKGRAY);
        EndDrawing();
    }
    CloseWindow();
    printf("rlmouse: ok\n");
    return 0;
}
