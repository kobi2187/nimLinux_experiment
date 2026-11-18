/* SPDX-License-Identifier: GPL-2.0
 * Host test of libnimix/nimix_display.h. Usage: test_display <port_vectors.txt>.
 *   1. every "request" line of the GENERATED vectors: calling the library function with those arguments must
 *      send exactly the bytes the real Nim encoder made;
 *   2. replies (built with the generated structs) are read back correctly, and status codes map to the old
 *      return values (-1 bad request, -3 no device). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../../libnimix/nimix_display.h"

static int fails;
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); fails++; } } while (0)

static unsigned char last_req[NIMIX_PORT_MSG];
static int last_len;
static unsigned reply_status;          /* what the fake device answers */

int nimixPortEvent(NimixHandle h, void *b, int cap) { (void)h; (void)b; (void)cap; return 0; }
int nimixPortCall(NimixHandle h, void *buf, int len, int cap) {
    unsigned char *m = buf; (void)cap;
    if (h != NIMIX_BOOTSTRAP_HANDLE) return -1;
    unsigned op = m[2] | (m[3] << 8);
    if (op == NIMIX_PORT_DESCRIBE_OP) { m[0] = NIMIX_MsgClass_mcReply; m[1] = 0; m[8] = 1; m[9] = 0; m[12] = NIMIX_PortKind_pkDisplay; return 13; }
    memcpy(last_req, m, len); last_len = len;
    unsigned char r[NIMIX_PORT_MSG] = { 0 };
    r[0] = NIMIX_MsgClass_mcReply; r[1] = (unsigned char)reply_status; r[2] = m[2]; r[3] = m[3];
    unsigned plen = 0;
    if (reply_status == NIMIX_PortStatus_psOk) {
        if (op == NIMIX_DisplayOp_doInfo) {
            NimixDisplayInfoWire w = { 1280, 800, NIMIX_DISPLAY_FORMAT_B8G8R8X8, 5120 };
            memcpy(r + NIMIX_PORT_HEADER, &w, sizeof w); plen = sizeof w;
        }
        if (op == NIMIX_DisplayOp_doModes) {
            NimixDisplayModesWire w = { 3, { { 800, 600 }, { 1024, 768 }, { 1280, 800 } } };
            memcpy(r + NIMIX_PORT_HEADER, &w, sizeof w); plen = sizeof w;
        }
    }
    r[8] = plen & 0xFF; r[9] = plen >> 8;
    memcpy(m, r, NIMIX_PORT_HEADER + plen);
    return NIMIX_PORT_HEADER + plen;
}

static void hex(const unsigned char *p, int n, char *out) { for (int i = 0; i < n; i++) sprintf(out + 2 * i, "%02x", p[i]); out[2 * n] = 0; }

static void vectors(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) { printf("FAIL cannot open %s\n", path); fails++; return; }
    char line[1024];
    int seen = 0;
    reply_status = NIMIX_PortStatus_psOk;
    while (fgets(line, sizeof line, f)) {
        if (strncmp(line, "request ", 8) != 0) continue;
        char kind[16]; long v[8] = { 0 };
        int got = sscanf(line, "request %15s %ld %ld %ld %ld %ld %ld %ld %ld", kind, v, v + 1, v + 2, v + 3, v + 4, v + 5, v + 6, v + 7);
        (void)got;
        NimixDisplayInfo info; NimixDisplayMode ms[8];
        if (!strcmp(kind, "info")) nimixDisplayInfo(&info);
        else if (!strcmp(kind, "modes")) nimixDisplayModes(ms, 8);
        else if (!strcmp(kind, "setmode")) nimixDisplaySetMode((unsigned)v[0], (unsigned)v[1]);
        else if (!strcmp(kind, "present")) {
            NimixPresent q = { sizeof q, (unsigned)v[0], (unsigned)v[1], (int)v[2], (int)v[3], (int)v[4], (int)v[5], (int)v[6], (int)v[7] };
            nimixDisplayPresent(&q);
        } else { printf("FAIL unknown request kind %s\n", kind); fails++; continue; }
        char want[1024], have[1024];
        const char *w = strstr(line, "= ") + 2;
        strncpy(want, w, sizeof want - 1); want[strcspn(want, "\n")] = 0;
        hex(last_req, last_len, have);
        if (strcmp(want, have)) { printf("FAIL %s sent %s, wanted %s\n", kind, have, want); fails++; }
        seen++;
    }
    fclose(f);
    CHECK(seen == 4);                                    /* info, modes, setmode, present */
}

int main(int argc, char **argv) {
    if (argc < 2) { printf("usage: test_display <port_vectors.txt>\n"); return 2; }
    vectors(argv[1]);
    NimixDisplayInfo info; NimixDisplayMode ms[8]; NimixPresent q = { sizeof q, 7, 2560, 1, 2, 640, 400, -10, 20 };
    reply_status = NIMIX_PortStatus_psOk;
    CHECK(nimixDisplayInfo(&info) == 0 && info.width == 1280 && info.height == 800 && info.format == 1 && info.stride_bytes == 5120);
    CHECK(nimixDisplayModes(NULL, 0) == 3);                              /* count only */
    CHECK(nimixDisplayModes(ms, 2) == 3 && ms[0].width == 800 && ms[1].height == 768);   /* writes at most max */
    CHECK(nimixDisplayInfo(NULL) == -1 && nimixDisplayPresent(NULL) == -1);
    NimixPresent small = q; small.size = 4;
    CHECK(nimixDisplayPresent(&small) == -1);
    reply_status = NIMIX_PortStatus_psBadArg; CHECK(nimixDisplayPresent(&q) == -1 && nimixDisplaySetMode(1, 1) == -1);
    reply_status = NIMIX_PortStatus_psNoDevice; CHECK(nimixDisplayInfo(&info) == -3);
    printf(fails ? "test_display: %d FAILED\n" : "test_display: all ok\n", fails);
    return fails != 0;
}
