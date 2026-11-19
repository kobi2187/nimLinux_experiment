/* SPDX-License-Identifier: GPL-2.0
 * Host test of libnimix/nimix_input.h. Usage: test_input <port_vectors.txt>.
 *   1. every "event" line of the GENERATED vectors (bytes made by the real Nim encoders) must decode to
 *      the fields on that line;
 *   2. hostile and truncated messages are refused whole. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../../libnimix/nimix_input.h"

int nimixPortCall(NimixHandle h, void *b, int len, int cap) { (void)h; (void)b; (void)len; (void)cap; return -1; }
int nimixPortEvent(NimixHandle h, void *b, int cap) { (void)h; (void)b; (void)cap; return 0; }

static int fails;
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); fails++; } } while (0)

static int unhex(const char *s, unsigned char *out) {
    int n = 0;
    for (; s[0] && s[1] && s[0] != '\n'; s += 2) { char b[3] = { s[0], s[1], 0 }; out[n++] = (unsigned char)strtoul(b, 0, 16); }
    return n;
}

static void vectors(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) { printf("FAIL cannot open %s\n", path); fails++; return; }
    char line[1024];
    int events = 0;
    while (fgets(line, sizeof line, f)) {
        char kind[16]; long a, b, c, d;
        if (strncmp(line, "event ", 6) != 0) continue;
        if (sscanf(line, "event %15s %ld %ld %ld %ld", kind, &a, &b, &c, &d) != 5) { printf("FAIL bad vector line: %s", line); fails++; continue; }
        unsigned char m[NIMIX_PORT_MSG];
        int n = unhex(strstr(line, "= ") + 2, m);
        NimixInputEvent ev;
        if (!nimix_input_decode(m, n, &ev)) { printf("FAIL did not decode: %s", line); fails++; continue; }
        events++;
        if (!strcmp(kind, "key"))         CHECK(ev.kind == NIMIX_IN_KEY && (long)ev.code == a && ev.value == b);
        else if (!strcmp(kind, "motion")) CHECK(ev.kind == NIMIX_IN_MOTION && ev.x == a && ev.y == b && ev.absolute == c);
        else if (!strcmp(kind, "button")) CHECK(ev.kind == NIMIX_IN_BUTTON && (long)ev.code == a && ev.value == b);
        else if (!strcmp(kind, "wheel"))  CHECK(ev.kind == NIMIX_IN_WHEEL && ev.x == a && ev.y == b);
        else if (!strcmp(kind, "lost"))   CHECK(ev.kind == NIMIX_IN_LOST && ev.value == a);
        else { printf("FAIL unknown event kind %s\n", kind); fails++; }
    }
    fclose(f);
    CHECK(events >= 8);                                   /* the vectors really were read */
}

static int msg(unsigned char *m, unsigned op, const unsigned char *payload, unsigned plen) {
    memset(m, 0, NIMIX_PORT_MSG);
    m[0] = NIMIX_MsgClass_mcEvent; m[2] = op & 0xFF; m[3] = op >> 8; m[8] = plen & 0xFF; m[9] = plen >> 8;
    if (plen) memcpy(m + NIMIX_PORT_HEADER, payload, plen);
    return NIMIX_PORT_HEADER + plen;
}

int main(int argc, char **argv) {
    if (argc < 2) { printf("usage: test_input <port_vectors.txt>\n"); return 2; }
    vectors(argv[1]);
    unsigned char m[NIMIX_PORT_MSG];
    NimixInputEvent ev;
    { unsigned char p[] = { 30, 0, 3 }; int n = msg(m, NIMIX_InputKind_ikKey, p, 3);       /* no such key action */
      CHECK(!nimix_input_decode(m, n, &ev)); }
    { unsigned char p[] = { 30, 0, 1 }; int n = msg(m, NIMIX_InputKind_ikKey, p, 3);
      m[0] = NIMIX_MsgClass_mcReply; CHECK(!nimix_input_decode(m, n, &ev));                /* a reply is not an event */
      m[0] = NIMIX_MsgClass_mcEvent; CHECK(!nimix_input_decode(m, n - 1, &ev));            /* truncated */
      m[8] = 9; CHECK(!nimix_input_decode(m, n, &ev)); }                                   /* length field disagrees */
    { int n = msg(m, 77, NULL, 0); CHECK(!nimix_input_decode(m, n, &ev)); }                /* unknown event kind */
    { unsigned char p[] = { 1, 2 }; int n = msg(m, NIMIX_InputKind_ikKey, p, 2); CHECK(!nimix_input_decode(m, n, &ev)); }
    CHECK(!nimix_input_decode(m, 3, &ev));
    printf(fails ? "test_input: %d FAILED\n" : "test_input: all ok\n", fails);
    return fails != 0;
}
