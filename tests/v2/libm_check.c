// SPDX-License-Identifier: GPL-2.0
// Runs picolibc's libm natively (static, freestanding, no OS layer: only the
// Linux write/exit syscalls to report) over a fixed pseudo-random grid and
// prints raw result bits. tests/v2/check_libm.py compares them with exact
// references (Python's correctly rounded double libm) in ULPs.
//
// Why: raylib/rlsw draw with sinf/cosf/powf/atan2f/... A function that is a few
// ULPs off shows up as subtle pixel differences between the direct and the
// remote render path and between machines, so the math library is a test
// subject like any other component.
#include <math.h>
#include <stdint.h>

static long sys3(long n, long a, long b, long c) {
    long r;
    __asm__ volatile("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c) : "rcx", "r11", "memory");
    return r;
}
static void out(const char *s, int n) { sys3(1, 1, (long)s, n); }
static int hex(char *p, uint64_t v, int digits) {
    for (int i = digits - 1; i >= 0; i--, v >>= 4) p[i] = "0123456789abcdef"[v & 15];
    return digits;
}
static uint32_t f2b(float f) { union { float f; uint32_t u; } x = { f }; return x.u; }
static uint64_t d2b(double d) { union { double d; uint64_t u; } x = { d }; return x.u; }

static uint32_t rng = 0x2545F491u;
static double unit(void) {            // deterministic [0,1)
    rng = rng * 1664525u + 1013904223u;
    return (rng >> 8) / 16777216.0;
}

// One output line: "<name> <in1> [<in2>] <result> [<result2>]" in hex bit patterns.
static void line(const char *name, int nin, uint64_t a, uint64_t b, int w, uint64_t r1, int has2, uint64_t r2) {
    char buf[96]; int n = 0;
    while (*name) buf[n++] = *name++;
    buf[n++] = ' '; n += hex(buf + n, a, w);
    if (nin == 2) { buf[n++] = ' '; n += hex(buf + n, b, w); }
    buf[n++] = ' '; n += hex(buf + n, r1, w);
    if (has2) { buf[n++] = ' '; n += hex(buf + n, r2, w); }
    buf[n++] = '\n';
    out(buf, n);
}

#define F1(name, fn, lo, hi) for (int i = 0; i < 400; i++) { \
    float x = (float)((lo) + ((hi) - (lo)) * unit()); \
    line(name, 1, f2b(x), 0, 8, f2b(fn(x)), 0, 0); }
#define F2(name, fn, lo1, hi1, lo2, hi2) for (int i = 0; i < 400; i++) { \
    float x = (float)((lo1) + ((hi1) - (lo1)) * unit()), y = (float)((lo2) + ((hi2) - (lo2)) * unit()); \
    line(name, 2, f2b(x), f2b(y), 8, f2b(fn(x, y)), 0, 0); }
#define D1(name, fn, lo, hi) for (int i = 0; i < 400; i++) { \
    double x = (lo) + ((hi) - (lo)) * unit(); \
    line(name, 1, d2b(x), 0, 16, d2b(fn(x)), 0, 0); }
#define D2(name, fn, lo1, hi1, lo2, hi2) for (int i = 0; i < 400; i++) { \
    double x = (lo1) + ((hi1) - (lo1)) * unit(), y = (lo2) + ((hi2) - (lo2)) * unit(); \
    line(name, 2, d2b(x), d2b(y), 16, d2b(fn(x, y)), 0, 0); }

void _start(void) {
    F1("sinf", sinf, -100.0, 100.0)   F1("cosf", cosf, -100.0, 100.0)
    F1("sqrtf", sqrtf, 0.0, 1.0e6)    F1("logf", logf, 1.0e-6, 1.0e6)
    F1("acosf", acosf, -1.0, 1.0)     F1("asinf", asinf, -1.0, 1.0)
    F2("powf", powf, 0.01, 20.0, -6.0, 6.0)
    F2("atan2f", atan2f, -50.0, 50.0, -50.0, 50.0)
    F2("fmodf", fmodf, -1000.0, 1000.0, 0.5, 90.0)
    F2("hypotf", hypotf, -1000.0, 1000.0, -1000.0, 1000.0)
    for (int i = 0; i < 400; i++) {                      // sincosf: both outputs
        float x = (float)(-100.0 + 200.0 * unit()), s, c;
        sincosf(x, &s, &c);
        line("sincosf", 1, f2b(x), 0, 8, f2b(s), 1, f2b(c));
    }
    D1("sqrt", sqrt, 0.0, 1.0e12)     D1("cos", cos, -100.0, 100.0)
    D1("tan", tan, -1.5, 1.5)         D1("acos", acos, -1.0, 1.0)
    D2("pow", pow, 0.01, 20.0, -6.0, 6.0)
    D2("fmod", fmod, -1000.0, 1000.0, 0.5, 90.0)
    D2("hypot", hypot, -1000.0, 1000.0, -1000.0, 1000.0)
    for (int i = 0; i < 400; i++) {                      // frexp: mantissa + exponent
        double x = (unit() - 0.5) * 1.0e9; int e;
        double m = frexp(x, &e);
        line("frexp", 1, d2b(x), 0, 16, d2b(m), 1, (uint64_t)(uint32_t)e);
    }
    sys3(60, 0, 0, 0);                                   // exit(0)
    for (;;) {}
}
