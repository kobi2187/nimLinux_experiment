/* SPDX-License-Identifier: GPL-2.0
 * rldemo — a raylib program on NimixOS: raylib 6.2 + the rlsw software renderer, drawing
 * into an owned buffer that the display ABI presents (PLATFORM_NIMIX, tools/raylib_nimix.py).
 *   rldemo        draw the scene, present it
 *   rldemo hold   ... and keep the screen for 8 s (the test takes a screendump) */
#include <stdio.h>
#include <string.h>
#include <time.h>
#include "raylib.h"
#include "rldemo_scene.h"

int main(int argc, char **argv) {
    InitWindow(RLDEMO_W, RLDEMO_H, "rldemo");
    if (!IsWindowReady()) { printf("rldemo: FAIL window\n"); return 1; }
    for (int frame = 0; frame < 3; frame++) {      /* a few frames: the path is a loop, not a one-off */
        BeginDrawing();
        rldemo_draw();
        EndDrawing();
    }
    printf("rldemo: presented %dx%d\n", RLDEMO_W, RLDEMO_H);
    if (argc > 1 && !strcmp(argv[1], "hold")) {
        struct timespec t = { 8, 0 };
        nanosleep(&t, NULL);
    }
    CloseWindow();
    printf("rldemo: ok\n");
    return 0;
}
