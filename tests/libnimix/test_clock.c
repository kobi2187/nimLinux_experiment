/* SPDX-License-Identifier: GPL-2.0
 * Host test for libnimix's clock reader (libnimix/nimix_timepage.h): it must
 * reproduce, bit for bit, every line of clock_vectors.txt (generated from the
 * Nim authority, core/tsc_clock.nim), and agree with an exact 128-bit
 * computation to within the multiplier's own quantisation. */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "nimix_timepage.h"

int main(int argc, char **argv) {
    FILE *f = fopen(argc > 1 ? argv[1] : "tests/libnimix/clock_vectors.txt", "r");
    if (!f) { perror("clock_vectors.txt"); return 1; }
    char line[256];
    int n = 0, bad = 0;
    while (fgets(line, sizeof line, f)) {
        if (line[0] == '#' || line[0] == '\n') continue;
        uint64_t hz, base, tsc, want; uint32_t mul, shift;
        if (sscanf(line, "%" SCNu64 " %" SCNu64 " %" SCNu32 " %" SCNu32 " %" SCNu64 " %" SCNu64,
                   &hz, &base, &mul, &shift, &tsc, &want) != 6) { fprintf(stderr, "bad line: %s", line); return 1; }
        NimixTimePage p = { NIMIX_TIME_PAGE_MAGIC, NIMIX_TIME_PAGE_VERSION, 1, base, hz, mul, shift };
        if (!nimix_timepage_valid(&p)) { printf("FAIL: page for hz=%" PRIu64 " not valid\n", hz); bad++; continue; }
        uint64_t got = nimix_timepage_nanos(&p, tsc);
        if (got != want) { printf("FAIL: hz=%" PRIu64 " tsc=%" PRIu64 ": C %" PRIu64 " != Nim %" PRIu64 "\n", hz, tsc, got, want); bad++; }
        /* exact reference: floor(delta * 1e9 / hz); error bound 1/mul (+1 ns) */
        unsigned __int128 exact = ((unsigned __int128)(tsc - base) * 1000000000ull) / hz;
        if (exact < ((unsigned __int128)1 << 64)) {
            uint64_t e = (uint64_t)exact, err = got > e ? got - e : e - got;
            if (err > e / mul + 1) { printf("FAIL: hz=%" PRIu64 " error %" PRIu64 " beyond 1/mul\n", hz, err); bad++; }
        }
        n++;
    }
    fclose(f);
    /* Refused pages: same cases as the Nim test. */
    NimixTimePage good = { NIMIX_TIME_PAGE_MAGIC, NIMIX_TIME_PAGE_VERSION, 1, 0, 2000000000ull, 2147483648u, 31 };
    NimixTimePage b;
    b = good; b.magic = 0;        if (nimix_timepage_valid(&b)) { puts("FAIL: wrong magic accepted"); bad++; }
    b = good; b.version = 2;      if (nimix_timepage_valid(&b)) { puts("FAIL: version 2 accepted"); bad++; }
    b = good; b.valid = 0;        if (nimix_timepage_valid(&b)) { puts("FAIL: not-calibrated accepted"); bad++; }
    b = good; b.shift = 0;        if (nimix_timepage_valid(&b)) { puts("FAIL: shift 0 accepted"); bad++; }
    b = good; b.shift = 33;       if (nimix_timepage_valid(&b)) { puts("FAIL: shift 33 accepted"); bad++; }
    b = good; b.mul = 0;          if (nimix_timepage_valid(&b)) { puts("FAIL: mul 0 accepted"); bad++; }
    memset(&b, 0, sizeof b);      if (nimix_timepage_valid(&b)) { puts("FAIL: zero page accepted"); bad++; }
    if (NIMIX_TIME_PAGE_ADDR != 224ull * 1024 * 1024) { puts("FAIL: page address"); bad++; }
    if (bad) { printf("FAIL: %d problems over %d vectors\n", bad, n); return 1; }
    printf("PASS: libnimix clock reader == core/tsc_clock.nim on %d golden vectors; refuses bad pages\n", n);
    return 0;
}
