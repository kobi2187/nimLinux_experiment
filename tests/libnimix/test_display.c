/* SPDX-License-Identifier: GPL-2.0
 * Host test of libnimix/nimix_display.h: a fake display port (nimixPortCall) checks the exact bytes each
 * library function sends, and the status-to-return-code mapping, including "no port held". */
#include <stdio.h>
#include <string.h>
#include "../../libnimix/nimix_display.h"

static int fails;
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); fails++; } } while (0)

static int have_port = 1;          /* does handle BOOTSTRAP+0 answer as a display port? */
static unsigned char last_req[NIMIX_PORT_MSG];
static int last_len;
static unsigned reply_status;      /* what the fake device answers */

int nimixPortEvent(NimixHandle h, void *b, int cap) { (void)h; (void)b; (void)cap; return 0; }
int nimixPortCall(NimixHandle h, void *buf, int len, int cap) {
    unsigned char *m = buf; (void)cap;
    if (!have_port || h != NIMIX_BOOTSTRAP_HANDLE) return -1;
    unsigned op = m[2] | (m[3] << 8);
    if (op == NIMIX_PORT_DESCRIBE_OP) { m[0] = 1; m[1] = 0; m[8] = 1; m[9] = 0; m[12] = NIMIX_PORT_DISPLAY; return 13; }
    memcpy(last_req, m, len); last_len = len;
    unsigned char r[NIMIX_PORT_MSG] = { 0 };
    r[0] = 1; r[1] = (unsigned char)reply_status; r[2] = m[2]; r[3] = m[3];
    int plen = 0;
    if (reply_status == 0) {
        if (op == 0) { nimix_put32(r + 12, 1280); nimix_put32(r + 16, 800); nimix_put32(r + 20, 1); nimix_put32(r + 24, 5120); plen = 16; }
        if (op == 1) { r[12] = 3; nimix_put32(r + 13, 800); nimix_put32(r + 17, 600); nimix_put32(r + 21, 1024); nimix_put32(r + 25, 768);
                       nimix_put32(r + 29, 1280); nimix_put32(r + 33, 800); plen = 65; }
    }
    r[8] = plen & 0xFF; r[9] = plen >> 8;
    memcpy(m, r, NIMIX_PORT_HEADER + plen);
    return NIMIX_PORT_HEADER + plen;
}

int main(void) {
    NimixDisplayInfo info; NimixDisplayMode ms[8]; NimixPresent q = { sizeof q, 7, 2560, 1, 2, 640, 400, -10, 20 };
    reply_status = 0;
    CHECK(nimixDisplayInfo(&info) == 0 && info.width == 1280 && info.height == 800 && info.format == 1 && info.stride_bytes == 5120);
    CHECK(nimixDisplayModes(NULL, 0) == 3);                              /* count only */
    CHECK(nimixDisplayModes(ms, 2) == 3 && ms[0].width == 800 && ms[1].height == 768);   /* writes at most max */
    CHECK(nimixDisplaySetMode(800, 600) == 0 && last_req[2] == 2 && nimix_le32(last_req + 12) == 800 && nimix_le32(last_req + 16) == 600);
    CHECK(nimixDisplayPresent(&q) == 0 && last_req[2] == 3 && last_len == 12 + 32);
    CHECK(nimix_le32(last_req + 12) == 7 && nimix_le32(last_req + 16) == 2560 && nimix_le32(last_req + 20) == 1 &&
          nimix_le32(last_req + 24) == 2 && nimix_le32(last_req + 28) == 640 && nimix_le32(last_req + 32) == 400 &&
          nimix_le32(last_req + 36) == -10 && nimix_le32(last_req + 40) == 20);
    /* argument checks that need no device */
    CHECK(nimixDisplayInfo(NULL) == -1 && nimixDisplayPresent(NULL) == -1);
    NimixPresent small = q; small.size = 4;
    CHECK(nimixDisplayPresent(&small) == -1);
    /* status mapping: a refused request is -1, no hardware is -3 */
    reply_status = 3; CHECK(nimixDisplayPresent(&q) == -1 && nimixDisplaySetMode(1, 1) == -1);
    reply_status = 10; CHECK(nimixDisplayInfo(&info) == -3);
    printf(fails ? "test_display: %d FAILED\n" : "test_display: all ok\n", fails);
    return fails != 0;
}
