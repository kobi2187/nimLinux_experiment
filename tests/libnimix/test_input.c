/* SPDX-License-Identifier: GPL-2.0
 * Host test of libnimix/nimix_input.h: the wire decoding of the input port's events (hand-built bytes
 * following ipc/ports/port.nim + input_port.nim) and that hostile messages are refused whole. */
#include <stdio.h>
#include <string.h>
#include "../../libnimix/nimix_input.h"

int nimixPortCall(NimixHandle h, void *b, int len, int cap) { (void)h; (void)b; (void)len; (void)cap; return -1; }
int nimixPortEvent(NimixHandle h, void *b, int cap) { (void)h; (void)b; (void)cap; return 0; }

static int fails;
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); fails++; } } while (0)

static int msg(unsigned char *m, unsigned op, const unsigned char *payload, unsigned plen) {
    memset(m, 0, NIMIX_PORT_MSG);
    m[0] = 2; m[2] = op & 0xFF; m[3] = op >> 8; m[8] = plen & 0xFF; m[9] = plen >> 8;
    if (plen) memcpy(m + NIMIX_PORT_HEADER, payload, plen);
    return NIMIX_PORT_HEADER + plen;
}

int main(void) {
    unsigned char m[NIMIX_PORT_MSG];
    NimixInputEvent ev;
    { unsigned char p[] = { 30, 0, 1 };  int n = msg(m, 0, p, 3);
      CHECK(nimix_input_decode(m, n, &ev) && ev.kind == NIMIX_IN_KEY && ev.code == 30 && ev.value == 1); }
    { unsigned char p[] = { 30, 0, 2 };  int n = msg(m, 0, p, 3);
      CHECK(nimix_input_decode(m, n, &ev) && ev.value == 2); }
    { unsigned char p[] = { 30, 0, 3 };  int n = msg(m, 0, p, 3);          /* no such key action */
      CHECK(!nimix_input_decode(m, n, &ev)); }
    { unsigned char p[] = { 0xFB, 0xFF, 0xFF, 0xFF, 0x2C, 0x01, 0, 0, 0 }; int n = msg(m, 1, p, 9);   /* dx=-5 dy=300 relative */
      CHECK(nimix_input_decode(m, n, &ev) && ev.kind == NIMIX_IN_MOTION && ev.x == -5 && ev.y == 300 && !ev.absolute); }
    { unsigned char p[] = { 0xFF, 0x7F, 0, 0, 0, 0x40, 0, 0, 1 }; int n = msg(m, 1, p, 9);            /* absolute 32767, 16384 */
      CHECK(nimix_input_decode(m, n, &ev) && ev.absolute && ev.x == 32767 && ev.y == 16384); }
    { unsigned char p[] = { 0x10, 0x01, 1 }; int n = msg(m, 2, p, 3);       /* button 272 pressed */
      CHECK(nimix_input_decode(m, n, &ev) && ev.kind == NIMIX_IN_BUTTON && ev.code == 272 && ev.value == 1); }
    { unsigned char p[] = { 0xFF, 0xFF, 0x03, 0 }; int n = msg(m, 3, p, 4); /* wheel x=-1 y=3 */
      CHECK(nimix_input_decode(m, n, &ev) && ev.kind == NIMIX_IN_WHEEL && ev.x == -1 && ev.y == 3); }
    { unsigned char p[] = { 0x39, 0x30, 0, 0 }; int n = msg(m, NIMIX_PORT_LOST_OP, p, 4);   /* 12345 lost */
      CHECK(nimix_input_decode(m, n, &ev) && ev.kind == NIMIX_IN_LOST && ev.value == 12345); }
    /* hostile: wrong class, truncated, length lies, unknown op, wrong payload size */
    { unsigned char p[] = { 30, 0, 1 }; int n = msg(m, 0, p, 3);
      m[0] = 1; CHECK(!nimix_input_decode(m, n, &ev));                      /* a reply is not an event */
      m[0] = 2; CHECK(!nimix_input_decode(m, n - 1, &ev));                  /* truncated */
      m[8] = 9; CHECK(!nimix_input_decode(m, n, &ev)); }                    /* length field disagrees */
    { int n = msg(m, 77, NULL, 0); CHECK(!nimix_input_decode(m, n, &ev)); }
    { unsigned char p[] = { 1, 2 }; int n = msg(m, 0, p, 2); CHECK(!nimix_input_decode(m, n, &ev)); }
    CHECK(!nimix_input_decode(m, 3, &ev));
    printf(fails ? "test_input: %d FAILED\n" : "test_input: all ok\n", fails);
    return fails != 0;
}
