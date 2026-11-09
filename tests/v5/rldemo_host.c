/* SPDX-License-Identifier: GPL-2.0
 * The reference: the same rldemo scene rendered headless on the host (raylib's own
 * memory platform), written as a binary PPM. The NimixOS screendump must equal it. */
#include <stdio.h>
#include <stdlib.h>
#include "raylib.h"
#include "rlgl.h"
#include "../../apps/c/rldemo/rldemo_scene.h"

int main(int argc, char **argv) {
    SetTraceLogLevel(LOG_NONE);
    InitWindow(RLDEMO_W, RLDEMO_H, "rldemo-host");
    for (int frame = 0; frame < 3; frame++) { BeginDrawing(); rldemo_draw(); EndDrawing(); }
    unsigned char *rgba = malloc((size_t)RLDEMO_W * RLDEMO_H * 4);
    rlCopyFramebuffer(0, 0, RLDEMO_W, RLDEMO_H, PIXELFORMAT_UNCOMPRESSED_R8G8B8A8, rgba);
    FILE *f = fopen(argc > 1 ? argv[1] : "rldemo_host.ppm", "wb");
    fprintf(f, "P6\n%d %d\n255\n", RLDEMO_W, RLDEMO_H);
    /* raylib 6.2 rlsw delivers the "R8G8B8A8" readback as bytes B,G,R,A (see
     * tools/raylib_nimix.py): write the TRUE image, R,G,B. */
    for (int i = 0; i < RLDEMO_W * RLDEMO_H; i++) {
        unsigned char rgb[3] = { rgba[i * 4 + 2], rgba[i * 4 + 1], rgba[i * 4 + 0] };
        fwrite(rgb, 1, 3, f);
    }
    fclose(f);
    CloseWindow();
    return 0;
}
