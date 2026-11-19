/* SPDX-License-Identifier: GPL-2.0
 * The input port for C programs (K3): read typed events from the port handle given at spawn. Header-only,
 * host-tested (tests/libnimix/test_input.c, including the generated vectors in port_vectors.txt).
 * The payload layouts and the event numbers come from the generated libnimix/nimix_contract.h.
 *
 * A program gets this port only if its manifest says `grant input` and the system policy allows it
 * (apps/manifests); there is nothing to subscribe to by name. */
#pragma once
#include "nimix_abi.h"
#include "nimix_port.h"

typedef enum {
    NIMIX_IN_KEY = NIMIX_InputKind_ikKey, NIMIX_IN_MOTION = NIMIX_InputKind_ikMotion,
    NIMIX_IN_BUTTON = NIMIX_InputKind_ikButton, NIMIX_IN_WHEEL = NIMIX_InputKind_ikWheel,
    NIMIX_IN_LOST = NIMIX_InputKind_ikLost
} NimixInputKind;

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
    if (len < NIMIX_PORT_HEADER || m[0] != NIMIX_MsgClass_mcEvent) return 0;
    unsigned op = nimix_le16(m + 2), plen = nimix_le16(m + 8);
    if ((int)(NIMIX_PORT_HEADER + plen) != len) return 0;
    const unsigned char *p = m + NIMIX_PORT_HEADER;
    ev->code = 0; ev->value = 0; ev->x = ev->y = 0; ev->absolute = 0;
    if (op == NIMIX_PORT_LOST_OP) {
        NimixLostWire w;
        if (plen != sizeof w) return 0;
        __builtin_memcpy(&w, p, sizeof w);
        ev->kind = NIMIX_IN_LOST; ev->value = (int)w.count; return 1;
    }
    switch (op) {
    case NIMIX_InputKind_ikKey: {
        NimixKeyWire w;
        if (plen != sizeof w) return 0;
        __builtin_memcpy(&w, p, sizeof w);
        if (w.action > NIMIX_KeyAction_kaRepeat) return 0;
        ev->kind = NIMIX_IN_KEY; ev->code = w.code; ev->value = w.action; return 1;
    }
    case NIMIX_InputKind_ikMotion: {
        NimixMotionWire w;
        if (plen != sizeof w) return 0;
        __builtin_memcpy(&w, p, sizeof w);
        ev->kind = NIMIX_IN_MOTION; ev->x = w.dx; ev->y = w.dy; ev->absolute = w.absolute != 0; return 1;
    }
    case NIMIX_InputKind_ikButton: {
        NimixButtonWire w;
        if (plen != sizeof w) return 0;
        __builtin_memcpy(&w, p, sizeof w);
        ev->kind = NIMIX_IN_BUTTON; ev->code = w.button; ev->value = w.pressed != 0; return 1;
    }
    case NIMIX_InputKind_ikWheel: {
        NimixWheelWire w;
        if (plen != sizeof w) return 0;
        __builtin_memcpy(&w, p, sizeof w);
        ev->kind = NIMIX_IN_WHEEL; ev->x = w.x; ev->y = w.y; return 1;
    }
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
