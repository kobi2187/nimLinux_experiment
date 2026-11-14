/* SPDX-License-Identifier: GPL-2.0
 * rlkeys — keyboard input into raylib on NimixOS (V5c).
 *   D or Right  moves the square one step right, A or Left one step left
 *   any typed character is collected (shown, and printed when the program ends)
 *   Q (or Esc, raylib's default exit key) quits
 * Keys arrive on the kernel's "input" event topic as evdev events; libnimix's keymap
 * turns them into raylib's KeyboardKey values and characters (PLATFORM_NIMIX). */
#include <stdio.h>
#include <string.h>
#include "raylib.h"

#define STEP 20

int main(void) {
    InitWindow(640, 400, "rlkeys");
    if (!IsWindowReady()) { printf("rlkeys: FAIL window\n"); return 1; }
    SetTargetFPS(30);                              /* not a busy loop: nanosleep between frames */
    int x = 0;
    char text[40] = "";
    int len = 0, frames = 0;
    printf("rlkeys: ready\n");
    while (!WindowShouldClose()) {
        /* the exact key sequence the program received (raylib KeyboardKey values) */
        for (int k = GetKeyPressed(); k > 0; k = GetKeyPressed()) printf("rlkeys: key %d\n", k);
        int before = x;
        if (IsKeyPressed(KEY_D) || IsKeyPressed(KEY_RIGHT)) x++;
        if (IsKeyPressed(KEY_A) || IsKeyPressed(KEY_LEFT)) x--;
        if (x != before) printf("rlkeys: step %d\n", x);
        if (IsKeyPressed(KEY_Q)) break;
        for (int ch = GetCharPressed(); ch > 0; ch = GetCharPressed())
            if (ch != 'q' && ch != 'Q' && len < (int)sizeof text - 1) text[len++] = (char)ch;
        text[len] = 0;

        BeginDrawing();
        ClearBackground(RAYWHITE);
        DrawRectangle(20 + STEP * x, 150, 40, 40, RED);     /* 40x40 square, centre (40 + 20x, 170) */
        DrawText("rlkeys: D/A or arrows move, Q quits", 20, 20, 20, DARKGRAY);
        DrawText(text, 20, 80, 20, DARKBLUE);
        EndDrawing();
        frames++;
    }
    CloseWindow();
    printf("rlkeys: x=%d text=\"%s\" frames>0=%d\n", x, text, frames > 0);
    printf("rlkeys: ok\n");
    return 0;
}
