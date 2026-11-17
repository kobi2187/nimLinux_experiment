/* SPDX-License-Identifier: GPL-2.0
 * The display for C programs: the same four functions the old display syscalls had (info, present, modes,
 * setMode), now over the display PORT (docs/proposals/device_ports.md). A program has a display only if its
 * manifest says `grant display` and the system policy allows it; otherwise every call returns
 * NIMIX_E_NO_DISPLAY_PORT. Layout mirrors ipc/ports/display_port.nim. Header-only; host-tested
 * (tests/libnimix/test_display.c).
 *
 * Returns: 0 ok; -1 a bad request (or the call failed); -3 no display device; -4 this program holds no display port. */
#pragma once
#include "nimix_abi.h"
#include "nimix_port.h"

#define NIMIX_DISPLAY_FORMAT_B8G8R8X8 1       /* little-endian 32-bit pixels: B, G, R, unused */
#define NIMIX_E_NO_DISPLAY_PORT (-4)

typedef struct { unsigned size, width, height, format, stride_bytes; } NimixDisplayInfo;
typedef struct {
    unsigned size;          /* sizeof(NimixPresent) */
    unsigned handle;        /* an owned or sealed buffer you can read */
    unsigned stride_bytes;  /* bytes per row of that buffer */
    int sx, sy, w, h;       /* the rectangle in the buffer */
    int dx, dy;             /* where it lands on the display */
} NimixPresent;
typedef struct { unsigned width, height; } NimixDisplayMode;

enum { NIMIX_DISPLAY_OP_INFO = 0, NIMIX_DISPLAY_OP_MODES = 1, NIMIX_DISPLAY_OP_SETMODE = 2, NIMIX_DISPLAY_OP_PRESENT = 3 };
#define NIMIX_DISPLAY_MAX_MODES 8

static inline NimixHandle nimix_display_port(void) {
    static NimixHandle cached;                           /* found once per program */
    if (!cached) cached = nimix_find_port(NIMIX_PORT_DISPLAY);
    return cached;
}

/* One request; maps the port status to the old return codes. The reply payload is at reply + 12. */
static inline int nimix_display_call(unsigned op, const void *payload, unsigned plen, unsigned char *reply) {
    NimixHandle h = nimix_display_port();
    if (!h) return NIMIX_E_NO_DISPLAY_PORT;
    int st = nimix_port_request(h, op, payload, plen, reply);
    if (st == 0) return 0;
    return st == 10 ? -3 : -1;                           /* no device, else a bad request */
}

static inline void nimix_put32(unsigned char *p, uint32_t v) { p[0] = v & 0xFF; p[1] = (v >> 8) & 0xFF; p[2] = (v >> 16) & 0xFF; p[3] = (uint32_t)v >> 24; }

static inline int nimixDisplayInfo(NimixDisplayInfo *out) {
    if (!out) return -1;
    unsigned char r[NIMIX_PORT_MSG];
    int e = nimix_display_call(NIMIX_DISPLAY_OP_INFO, 0, 0, r);
    if (e) return e;
    if (nimix_le16(r + 8) != 16) return -1;
    out->size = sizeof *out;
    out->width = (unsigned)nimix_le32(r + 12); out->height = (unsigned)nimix_le32(r + 16);
    out->format = (unsigned)nimix_le32(r + 20); out->stride_bytes = (unsigned)nimix_le32(r + 24);
    return 0;
}

/* Writes up to `max` modes to out and returns how many modes exist (call with max 0 to count). */
static inline int nimixDisplayModes(NimixDisplayMode *out, int max) {
    unsigned char r[NIMIX_PORT_MSG];
    int e = nimix_display_call(NIMIX_DISPLAY_OP_MODES, 0, 0, r);
    if (e) return e;
    unsigned n = r[12];
    if (n > NIMIX_DISPLAY_MAX_MODES || nimix_le16(r + 8) != 1 + 8 * NIMIX_DISPLAY_MAX_MODES) return -1;
    if (max > 0 && out)
        for (unsigned i = 0; i < n && (int)i < max; i++) {
            out[i].width = (unsigned)nimix_le32(r + 13 + 8 * i);
            out[i].height = (unsigned)nimix_le32(r + 17 + 8 * i);
        }
    return (int)n;
}

static inline int nimixDisplaySetMode(unsigned width, unsigned height) {
    unsigned char p[8], r[NIMIX_PORT_MSG];
    nimix_put32(p, width); nimix_put32(p + 4, height);
    return nimix_display_call(NIMIX_DISPLAY_OP_SETMODE, p, sizeof p, r);
}

static inline int nimixDisplayPresent(const NimixPresent *req) {
    if (!req || req->size < sizeof *req) return -1;
    unsigned char p[32], r[NIMIX_PORT_MSG];
    nimix_put32(p, req->handle); nimix_put32(p + 4, req->stride_bytes);
    nimix_put32(p + 8, (uint32_t)req->sx); nimix_put32(p + 12, (uint32_t)req->sy);
    nimix_put32(p + 16, (uint32_t)req->w); nimix_put32(p + 20, (uint32_t)req->h);
    nimix_put32(p + 24, (uint32_t)req->dx); nimix_put32(p + 28, (uint32_t)req->dy);
    return nimix_display_call(NIMIX_DISPLAY_OP_PRESENT, p, sizeof p, r);
}
