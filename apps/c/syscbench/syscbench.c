/* SPDX-License-Identifier: GPL-2.0
 * syscbench — what do per-task address spaces cost? (S8)
 *   syscbench calls   nanoseconds per syscall (nimixKernelCalls, the cheapest one)
 *   syscbench spin    a fixed memory-touching workload, timed: run ONE copy, then TWO at once.
 *                     Two copies are switched between every 10 ms tick, so the slowdown of each
 *                     (beyond the 2x of sharing the CPU) is the cost of switching address spaces.
 * Under QEMU's TCG these are the emulator's numbers: compare variants, do not read them as hardware. */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>
#include "nimix_abi.h"

static long long now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "calls")) {
        const int N = 200000;
        nimixKernelCalls();
        long long t0 = now_us();
        for (int i = 0; i < N; i++) nimixKernelCalls();
        long long dt = now_us() - t0;
        printf("syscbench: calls %lld ns per syscall (%d calls)\n", dt * 1000 / N, N);
        return 0;
    }
    if (argc > 1 && !strcmp(argv[1], "spin")) {
        static volatile unsigned char buf[512 * 1024];     /* touches 512 KB: a working set that needs a TLB */
        long long t0 = now_us();
        unsigned acc = 1;
        for (int round = 0; round < 40000; round++)
            for (unsigned i = 0; i < sizeof buf; i += 64) { buf[i] = (unsigned char)(buf[i] + round + i); acc += buf[i]; }
        long long dt = now_us() - t0;
        printf("syscbench: spin %lld ms (acc %u)\n", dt / 1000, acc & 1);
        return 0;
    }
    printf("syscbench: usage: calls | spin\n");
    return 2;
}
