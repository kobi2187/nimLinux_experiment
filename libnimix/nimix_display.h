/* SPDX-License-Identifier: GPL-2.0
 * The display for C programs: the same four functions the old display syscalls had (info, present, modes,
 * setMode), now over the display PORT (docs/proposals/device_ports.md). A program has a display only if its
 * manifest says `grant display` and the system policy allows it; otherwise every call returns
 * NIMIX_E_NO_DISPLAY_PORT. Payload layouts and operation numbers come from the generated nimix_contract.h.
 * Header-only; host-tested (tests/libnimix/test_display.c, including the generated vectors).
 *
 * Returns: 0 ok; -1 a bad request (or the call failed); -3 no display device; -4 this program holds no display port. */
#pragma once
#include "nimix_abi.h"
#include "nimix_port.h"

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

static inline NimixHandle nimix_display_port(void) {
    static NimixHandle cached;                           /* found once per program */
    if (!cached) cached = nimix_find_port(NIMIX_PORT_DISPLAY);
    return cached;
}

/* One request; maps the port status to the old return codes. The reply payload is at reply + NIMIX_PORT_HEADER. */
static inline int nimix_display_call(unsigned op, const void *payload, unsigned plen, unsigned char *reply) {
    NimixHandle h = nimix_display_port();
    if (!h) return NIMIX_E_NO_DISPLAY_PORT;
    int st = nimix_port_request(h, op, payload, plen, reply);
    if (st == NIMIX_PortStatus_psOk) return 0;
    return st == NIMIX_PortStatus_psNoDevice ? -3 : -1;  /* no device, else a bad request */
}

static inline int nimixDisplayInfo(NimixDisplayInfo *out) {
    if (!out) return -1;
    unsigned char r[NIMIX_PORT_MSG];
    int e = nimix_display_call(NIMIX_DisplayOp_doInfo, 0, 0, r);
    if (e) return e;
    NimixDisplayInfoWire w;
    if (nimix_le16(r + 8) != sizeof w) return -1;
    __builtin_memcpy(&w, r + NIMIX_PORT_HEADER, sizeof w);
    out->size = sizeof *out; out->width = w.width; out->height = w.height;
    out->format = w.format; out->stride_bytes = w.strideBytes;
    return 0;
}

/* Writes up to `max` modes to out and returns how many modes exist (call with max 0 to count). */
static inline int nimixDisplayModes(NimixDisplayMode *out, int max) {
    unsigned char r[NIMIX_PORT_MSG];
    int e = nimix_display_call(NIMIX_DisplayOp_doModes, 0, 0, r);
    if (e) return e;
    NimixDisplayModesWire w;
    if (nimix_le16(r + 8) != sizeof w) return -1;
    __builtin_memcpy(&w, r + NIMIX_PORT_HEADER, sizeof w);
    if (w.count > NIMIX_DISPLAY_MAX_MODES) return -1;
    if (max > 0 && out)
        for (unsigned i = 0; i < w.count && (int)i < max; i++) { out[i].width = w.modes[i].w; out[i].height = w.modes[i].h; }
    return (int)w.count;
}

static inline int nimixDisplaySetMode(unsigned width, unsigned height) {
    NimixSetModeWire w = { width, height };
    unsigned char r[NIMIX_PORT_MSG];
    return nimix_display_call(NIMIX_DisplayOp_doSetMode, &w, sizeof w, r);
}

static inline int nimixDisplayPresent(const NimixPresent *req) {
    if (!req || req->size < sizeof *req) return -1;
    NimixPresentWire w = { req->handle, req->stride_bytes, req->sx, req->sy, req->w, req->h, req->dx, req->dy };
    unsigned char r[NIMIX_PORT_MSG];
    return nimix_display_call(NIMIX_DisplayOp_doPresent, &w, sizeof w, r);
}
