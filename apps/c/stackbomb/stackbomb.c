/* SPDX-License-Identifier: GPL-2.0
 * stackbomb — what happens when a program overflows its own stack (guard page test).
 *   stackbomb ok     recurses 100 frames of 4 KB (about 400 KB, well inside the 1 MB stack): must finish
 *   stackbomb bomb   recurses without end: must be killed by a page fault in the guard page, BEFORE it can
 *                    touch the heap or its program image. It never prints "survived".
 * Each frame is a separate 4 KB volatile array, so the compiler cannot turn the recursion into a loop. */
#include <stdio.h>
#include <string.h>
#include "nimix_abi.h"

static int deepest;

static int recurse(int n, int limit) {
    volatile char frame[4096];
    frame[0] = (char)n; frame[4095] = (char)(n >> 1);
    deepest = n;
    if (limit && n >= limit) return frame[0] + frame[4095];
    return recurse(n + 1, limit) + frame[0];
}

int main(int argc, char **argv) {
    if (argc >= 2 && !strcmp(argv[1], "ok")) {
        recurse(0, 100);
        printf("stackbomb: ok, reached %d frames\n", deepest);
        return 0;
    }
    if (argc >= 2 && !strcmp(argv[1], "bomb")) {
        printf("stackbomb: recursing\n");
        recurse(0, 0);
        printf("stackbomb: survived\n");               /* must never print */
        return 3;
    }
    printf("stackbomb: usage: stackbomb ok|bomb\n");
    return 2;
}
