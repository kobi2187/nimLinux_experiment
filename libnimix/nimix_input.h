/* SPDX-License-Identifier: GPL-2.0
 * The input port for C programs (K3): find the port among the handles given at spawn, and read typed
 * events. Header-only, host-tested (tests/libnimix/test_input.c). The layout mirrors ipc/ports/port.nim
 * (the wire form) and ipc/ports/input_port.nim (the payloads); both are little endian and packed.
 *
 * A program gets this port only if its manifest says `grant input` and the system policy allows it
 * (apps/manifests); there is nothing to subscribe to by name. */
#pragma once
#include <stdint.h>
#include "nimix_abi.h"
#include "nimix_port.h"

typedef enum { NIMIX_IN_KEY, NIMIX_IN_MOTION, NIMIX_IN_BUTTON, NIMIX_IN_WHEEL, NIMIX_IN_LOST } NimixInputKind;

typedef struct {
    int kind;            /* NimixInputKind */
    unsigned code;       /* KEY: evdev key code; BUTTON: evdev button code (272 = left) */
    int value;           /* KEY: 0 release, 1 press, 2 repeat; BUTTON: 0 or 1; LOST: how many events */
    int x, y;            /* MOTION: dx,dy (relative) or the position 0..32767 (absolute); WHEEL: x,y */
    int absolute;        /* MOTION: 1 if x,y are a position */
} NimixInputEvent;

/* Decode one event message (wire form, `len` bytes). 1 if it is an event this header understands, else 0:
 * a hostile or truncated message is refused, never half-read. */
static inline int nimix_input_decode(const unsigned char *m, int len, NimixInputEvent *ev) {
    if (len < NIMIX_PORT_HEADER || m[0] != 2) return 0;                 /* class 2 = event */
    unsigned op = nimix_le16(m + 2), plen = nimix_le16(m + 8);
    if ((int)(NIMIX_PORT_HEADER + plen) != len) return 0;
    const unsigned char *p = m + NIMIX_PORT_HEADER;
    ev->code = 0; ev->value = 0; ev->x = ev->y = 0; ev->absolute = 0;
    if (op == NIMIX_PORT_LOST_OP) {
        if (plen != 4) return 0;
        ev->kind = NIMIX_IN_LOST; ev->value = nimix_le32(p); return 1;
    }
    switch (op) {
    case NIMIX_IN_KEY:
        if (plen != 3 || p[2] > 2) return 0;
        ev->kind = NIMIX_IN_KEY; ev->code = nimix_le16(p); ev->value = p[2]; return 1;
    case NIMIX_IN_MOTION:
        if (plen != 9) return 0;
        ev->kind = NIMIX_IN_MOTION; ev->x = nimix_le32(p); ev->y = nimix_le32(p + 4); ev->absolute = p[8] != 0; return 1;
    case NIMIX_IN_BUTTON:
        if (plen != 3) return 0;
        ev->kind = NIMIX_IN_BUTTON; ev->code = nimix_le16(p); ev->value = p[2] != 0; return 1;
    case NIMIX_IN_WHEEL:
        if (plen != 4) return 0;
        ev->kind = NIMIX_IN_WHEEL; ev->x = (int16_t)nimix_le16(p); ev->y = (int16_t)nimix_le16(p + 2); return 1;
    }
    return 0;                                                            /* an event kind this header does not know */
}

/* The next event of an input port handle: 1 and *ev filled, 0 none waiting, < 0 error. */
static inline int nimix_input_next(NimixHandle port, NimixInputEvent *ev) {
    unsigned char m[NIMIX_PORT_MSG];
    for (;;) {
        int n = nimixPortEvent(port, m, sizeof m);
        if (n <= 0) return n;
        if (nimix_input_decode(m, n, ev)) return 1;                      /* skip what cannot be understood */
    }
}

