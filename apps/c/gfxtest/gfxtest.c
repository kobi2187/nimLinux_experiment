/* SPDX-License-Identifier: GPL-2.0
 * gfxtest — the display ABI from ring 3 (docs/proposals/display_abi.md).
 *   gfxtest        refuse every bad request, then present a 640x400 pattern at (100, 50)
 *   gfxtest hold   ... and keep the screen for 8 s (the harness takes a screendump)
 * The pattern is a pure function of (x, y) so the host can recompute it exactly:
 *   R = x*255/639, G = y*255/399, B = (x ^ y) & 255, with a 1-pixel white border. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include "nimix_abi.h"

#define W 640
#define H 400
#define DX 100
#define DY 50

static int fails;
static void expect(int got, int want, const char *what) {
    if (got != want) { fails++; printf("gfxtest: FAIL %s: got %d, want %d\n", what, got, want); }
}

static uint32_t pattern(int x, int y) {
    if (x == 0 || y == 0 || x == W - 1 || y == H - 1) return 0xFFFFFFFFu;
    uint32_t r = (uint32_t)(x * 255 / (W - 1)), g = (uint32_t)(y * 255 / (H - 1)), b = (uint32_t)((x ^ y) & 255);
    return 0xFF000000u | (r << 16) | (g << 8) | b;          /* B8G8R8X8: B in the low byte */
}

int main(int argc, char **argv) {
    NimixDisplayInfo info = { sizeof info, 0, 0, 0, 0 };
    expect(nimixDisplayInfo(&info), 0, "display info");
    printf("gfxtest: display %ux%u format %u stride %u\n", info.width, info.height, info.format, info.stride_bytes);
    expect(info.format == NIMIX_DISPLAY_FORMAT_B8G8R8X8 && info.stride_bytes == info.width * 4, 1, "display format");

    int h = nimixBufCreate(W * H * 4);
    uint32_t *px = nimixBufMap((unsigned)h);
    if (h <= 0 || !px) { printf("gfxtest: FAIL no buffer\n"); return 1; }
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) px[y * W + x] = pattern(x, y);

    /* Refusals: each must return -1 and must NOT make us the display owner. */
    NimixPresent q = { sizeof q, (unsigned)h, W * 4, 0, 0, W, H, DX, DY };
    NimixPresent b;
    b = q; b.w = 0;                        expect(nimixDisplayPresent(&b), -1, "zero width");
    b = q; b.h = H + 1;                    expect(nimixDisplayPresent(&b), -1, "one row past the buffer");
    b = q; b.stride_bytes = 100;           expect(nimixDisplayPresent(&b), -1, "stride narrower than a row");
    b = q; b.dx = (int)info.width - 10;    expect(nimixDisplayPresent(&b), -1, "off the right edge");
    b = q; b.dy = -1;                      expect(nimixDisplayPresent(&b), -1, "negative destination");
    b = q; b.handle = 0xDEAD;              expect(nimixDisplayPresent(&b), -1, "a handle we do not hold");
    b = q; b.size = 4;                     expect(nimixDisplayPresent(&b), -1, "struct size too small");
    expect(nimixDisplayPresent(NULL), -1, "NULL request");
    expect(nimixDisplayPresent((const NimixPresent *)0x1000), -1, "request pointing into the kernel");
    expect(nimixDisplayInfo((NimixDisplayInfo *)0x1000), -1, "info written through a kernel pointer");

    expect(nimixDisplayPresent(&q), 0, "present");                       /* first success: we own the screen */
    expect(nimixBufSeal((unsigned)h), 0, "seal the frame");
    q.dx = DX; q.dy = DY;
    expect(nimixDisplayPresent(&q), 0, "present a sealed buffer");        /* read access is enough */

    if (!fails) printf("gfxtest: presented\n");
    if (argc > 1 && !strcmp(argv[1], "hold")) {
        struct timespec t = { 8, 0 };
        nanosleep(&t, NULL);
    }
    if (!fails) printf("gfxtest: ok\n");
    return fails ? 1 : 0;
}
