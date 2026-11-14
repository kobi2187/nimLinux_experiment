/* SPDX-License-Identifier: GPL-2.0
 * fputest — a ring-3 program's floating-point and SSE state must survive timer
 * interrupts, and must not leak between tasks.
 *
 * The timer (100 Hz) interrupts the program mid-computation. If the kernel's own
 * code uses xmm registers before it saves the program's FPU state, a program's
 * floats are silently corrupted. That is rare and timing-dependent (one wrong
 * sinf in a slow CI run), so this makes it certain: load all 16 xmm registers
 * and the x87 stack, spin in pure assembly (no compiler use of xmm) for ~8 ticks,
 * then store everything back and compare.
 *   fputest        survive: xmm0-15 + x87 across ~8 timer interrupts
 *   (always also)  a new task starts with the default state (xmm cleared) */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "nimix_timepage.h"

static int fails;
static void check(int ok, const char *what) {
    if (!ok) { fails++; printf("fputest: FAIL %s\n", what); }
}

/* The state a task must start with, whoever ran before it. */
static void test_clean_start(void) {
    uint8_t x[4][16] __attribute__((aligned(16)));
    __asm__ volatile("movdqa %%xmm0, 0(%0)\n movdqa %%xmm1, 16(%0)\n movdqa %%xmm2, 32(%0)\n"
                     "movdqa %%xmm3, 48(%0)" : : "r"(x) : "memory");
    int clean = 1;
    for (int i = 0; i < 4; i++) for (int j = 0; j < 16; j++) if (x[i][j]) clean = 0;
    check(clean, "a new task starts with cleared SSE registers (no leak from the task before)");
    unsigned short fcw; unsigned int mxcsr;
    __asm__ volatile("fnstcw %0" : "=m"(fcw));
    __asm__ volatile("stmxcsr %0" : "=m"(mxcsr));
    check(fcw == 0x037F && mxcsr == 0x1F80, "default x87 control word and MXCSR");
}

static void test_survives_ticks(void) {
    static uint8_t in[16][16] __attribute__((aligned(16)));
    static uint8_t out[16][16] __attribute__((aligned(16)));
    for (int i = 0; i < 16; i++) for (int j = 0; j < 16; j++) in[i][j] = (uint8_t)(0xA0 + i * 17 + j * 3);
    memset(out, 0, sizeof out);

    const NimixTimePage *p = (const NimixTimePage *)NIMIX_TIME_PAGE_ADDR;
    if (!nimix_timepage_valid(p)) { check(0, "time page valid"); return; }
    uint64_t span = p->hz / 12;                 /* ~83 ms: eight 10 ms timer ticks */
    uint64_t end = nimix_rdtsc() + span;
    double st0_in = 3.14159265358979, st0_out = 0.0;

    __asm__ volatile(
        "fldl %[x87in]\n"                               /* x87 stack: st0 = pi */
        "movdqu   0(%[in]), %%xmm0\n  movdqu  16(%[in]), %%xmm1\n  movdqu  32(%[in]), %%xmm2\n  movdqu  48(%[in]), %%xmm3\n"
        "movdqu  64(%[in]), %%xmm4\n  movdqu  80(%[in]), %%xmm5\n  movdqu  96(%[in]), %%xmm6\n  movdqu 112(%[in]), %%xmm7\n"
        "movdqu 128(%[in]), %%xmm8\n  movdqu 144(%[in]), %%xmm9\n  movdqu 160(%[in]), %%xmm10\n movdqu 176(%[in]), %%xmm11\n"
        "movdqu 192(%[in]), %%xmm12\n movdqu 208(%[in]), %%xmm13\n movdqu 224(%[in]), %%xmm14\n movdqu 240(%[in]), %%xmm15\n"
        "1:\n"                                          /* spin: general registers only */
        "rdtsc\n shlq $32, %%rdx\n orq %%rdx, %%rax\n cmpq %[end], %%rax\n jb 1b\n"
        "movdqu %%xmm0,    0(%[out])\n movdqu %%xmm1,   16(%[out])\n movdqu %%xmm2,   32(%[out])\n movdqu %%xmm3,   48(%[out])\n"
        "movdqu %%xmm4,   64(%[out])\n movdqu %%xmm5,   80(%[out])\n movdqu %%xmm6,   96(%[out])\n movdqu %%xmm7,  112(%[out])\n"
        "movdqu %%xmm8,  128(%[out])\n movdqu %%xmm9,  144(%[out])\n movdqu %%xmm10, 160(%[out])\n movdqu %%xmm11, 176(%[out])\n"
        "movdqu %%xmm12, 192(%[out])\n movdqu %%xmm13, 208(%[out])\n movdqu %%xmm14, 224(%[out])\n movdqu %%xmm15, 240(%[out])\n"
        "fstpl %[x87out]\n"
        : [x87out] "=m"(st0_out)
        : [in] "r"(in), [out] "r"(out), [end] "r"(end), [x87in] "m"(st0_in)
        : "rax", "rdx", "memory", "cc",
          "xmm0", "xmm1", "xmm2", "xmm3", "xmm4", "xmm5", "xmm6", "xmm7",
          "xmm8", "xmm9", "xmm10", "xmm11", "xmm12", "xmm13", "xmm14", "xmm15", "st");

    int bad = 0;
    for (int i = 0; i < 16; i++) if (memcmp(in[i], out[i], 16)) { bad++; printf("fputest: xmm%d changed\n", i); }
    check(bad == 0, "xmm0-15 survive timer interrupts");
    check(st0_out == st0_in, "the x87 stack survives timer interrupts");
}

int main(void) {
    test_clean_start();
    test_survives_ticks();
    if (!fails) printf("fputest: ok\n");
    return fails ? 1 : 0;
}
