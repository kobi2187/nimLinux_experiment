/* SPDX-License-Identifier: GPL-2.0
 * Host test for libnimix's pointer helpers (libnimix/nimix_pointer.h). Includes raylib.h,
 * so a renumbering of its MouseButton enum fails here. */
#include <stdio.h>
#include "raylib.h"
#include "nimix_pointer.h"

static int bad;
#define EXPECT(cond, ...) do { if (!(cond)) { bad++; printf("FAIL: " __VA_ARGS__); printf("\n"); } } while (0)

int main(void) {
    /* tablet scaling: ends, middle, rounding, and out-of-range input */
    EXPECT(nimix_abs_to_px(0, 1280) == 0, "left edge");
    EXPECT(nimix_abs_to_px(32767, 1280) == 1279, "right edge");
    EXPECT(nimix_abs_to_px(16384, 1280) == 640, "middle rounds up (639.5)");
    EXPECT(nimix_abs_to_px(8000, 1280) == 312, "8000 -> 312");
    EXPECT(nimix_abs_to_px(6000, 800) == 146, "6000 -> 146");
    EXPECT(nimix_abs_to_px(-5, 800) == 0, "negative clamps");
    EXPECT(nimix_abs_to_px(40000, 800) == 799, "too large clamps");
    EXPECT(nimix_abs_to_px(100, 1) == 0 && nimix_abs_to_px(100, 0) == 0, "degenerate extent");
    int prev = -1;                                   /* monotonic, and every pixel is reachable */
    for (int v = 0; v <= NIMIX_ABS_MAX; v++) {
        int p = nimix_abs_to_px(v, 1280);
        EXPECT(p >= prev && p - prev <= 1, "monotonic with no skipped pixel at %d", v);
        if (bad) break;
        prev = p;
    }
    /* relative motion clamps to the display */
    EXPECT(nimix_clamp_px(-3, 1280) == 0 && nimix_clamp_px(5000, 1280) == 1279 && nimix_clamp_px(77, 1280) == 77, "clamp");
    /* buttons */
    EXPECT(nimix_button_to_raylib(272) == MOUSE_BUTTON_LEFT, "left");
    EXPECT(nimix_button_to_raylib(273) == MOUSE_BUTTON_RIGHT, "right");
    EXPECT(nimix_button_to_raylib(274) == MOUSE_BUTTON_MIDDLE, "middle");
    EXPECT(nimix_button_to_raylib(271) == -1 && nimix_button_to_raylib(275) == -1 && nimix_button_to_raylib(30) == -1, "not a mouse button");
    if (bad) { printf("%d failures\n", bad); return 1; }
    printf("PASS: pointer scaling, clamping and buttons\n");
    return 0;
}
