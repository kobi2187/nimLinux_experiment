/* SPDX-License-Identifier: GPL-2.0
 * Pointer events for C programs (V5e): what the virtio mouse (EV_REL) and tablet (EV_ABS)
 * deliver on the "input" event topic, as evdev triples, turned into a position on the
 * display, buttons and a wheel. Pure, header-only, host-tested (tests/libnimix/test_pointer.c).
 *   mouse  : relative motion adds to a cursor the program keeps, clamped to the display
 *   tablet : absolute position, 0..32767 on each axis, scaled to the display
 *   buttons: EV_KEY BTN_LEFT/RIGHT/MIDDLE (272..274); the wheel is EV_REL REL_WHEEL (8) */
#pragma once
#include <stdint.h>

#define NIMIX_EV_REL 2u
#define NIMIX_EV_ABS 3u
#define NIMIX_REL_X 0u
#define NIMIX_REL_Y 1u
#define NIMIX_REL_WHEEL 8u
#define NIMIX_ABS_X 0u
#define NIMIX_ABS_Y 1u
#define NIMIX_ABS_MAX 32767
#define NIMIX_BTN_LEFT 272u

/* Tablet value (0..32767) to a pixel in 0..extent-1, rounded to nearest. */
static inline int nimix_abs_to_px(int32_t value, int extent) {
    if (extent <= 1) return 0;
    if (value < 0) value = 0;
    if (value > NIMIX_ABS_MAX) value = NIMIX_ABS_MAX;
    return (int)(((int64_t)value * (extent - 1) + NIMIX_ABS_MAX / 2) / NIMIX_ABS_MAX);
}

static inline int nimix_clamp_px(int64_t v, int extent) {
    if (v < 0) return 0;
    if (extent > 0 && v > extent - 1) return extent - 1;
    return (int)v;
}

/* evdev button code to raylib's MouseButton (left 0, right 1, middle 2), or -1. */
static inline int nimix_button_to_raylib(unsigned code) {
    switch (code) {
    case NIMIX_BTN_LEFT:      return 0;
    case NIMIX_BTN_LEFT + 1:  return 1;
    case NIMIX_BTN_LEFT + 2:  return 2;
    }
    return -1;
}
