/* SPDX-License-Identifier: GPL-2.0
 * rlbench — what does a raylib frame cost on NimixOS? (baseline for the render server, V6/V9)
 *   rlbench [width height frames]     default 640 400 30
 * Draws an RUI-like scene (rects, circles, lines, text) every frame into the software
 * renderer, then presents the whole frame, and reports milliseconds per frame split into
 * "draw" (the raylib calls until EndDrawing) and "end" (EndDrawing: readback into the display
 * format + nimixDisplayPresent = the kernel copy to the scanout and the virtio-gpu transfer).
 * Time comes from the fine clock (clock_gettime). Under QEMU's TCG the numbers are
 * the emulator's, not hardware's: they bound the cost, and tell where it goes. */
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include "raylib.h"

static long long now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (long long)t.tv_sec * 1000000000ll + t.tv_nsec;
}

int main(int argc, char **argv) {
    int w = argc > 1 ? atoi(argv[1]) : 640, h = argc > 2 ? atoi(argv[2]) : 400;
    int frames = argc > 3 ? atoi(argv[3]) : 30;
    InitWindow(w, h, "rlbench");
    if (!IsWindowReady()) { printf("rlbench: FAIL window\n"); return 1; }
    long long draw = 0, end = 0;
    for (int f = 0; f < frames; f++) {
        long long t0 = now_ns();
        BeginDrawing();
        ClearBackground(RAYWHITE);
        for (int i = 0; i < 12; i++) {                         /* a screenful of widget-like shapes */
            DrawRectangle(10 + i * 8, 10 + i * 6, w / 3, h / 6, (Color){ (unsigned char)(20 * i), 121, 241, 255 });
            DrawCircle(w / 2 + i * 5, h / 2, 24, MAROON);
            DrawLine(0, i * 20, w - 1, h - 1 - i * 10, DARKGRAY);
        }
        DrawText("rlbench: a frame of text", 20, 20, 20, DARKGRAY);
        long long t1 = now_ns();
        EndDrawing();
        long long t2 = now_ns();
        draw += t1 - t0;
        end += t2 - t1;
    }
    CloseWindow();
    printf("rlbench: %dx%d frames=%d draw=%lld us/frame end=%lld us/frame\n", w, h, frames,
           draw / frames / 1000, end / frames / 1000);
    printf("rlbench: ok\n");
    return 0;
}
