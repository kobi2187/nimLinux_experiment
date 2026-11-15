/* SPDX-License-Identifier: GPL-2.0
 * isotest — is one running app's memory really out of another's reach? (S8, per-task address spaces)
 * Run by the shell's `isotest` command, which keeps a victim alive and sends attackers at it.
 *   isotest victim            plants a secret in its own region and in an owned buffer, sleeps 5 s,
 *                             then checks the secrets are intact
 *   isotest own               positive control: touches its OWN region and buffer (must work)
 *   isotest read  <addr>      tries to READ another address   (must fault: the kernel kills this app)
 *   isotest write <addr>      tries to WRITE another address  (must fault)
 *   isotest neighbor <addr>   owns a 4 KB buffer of its own right next to the victim's (the same 2 MB
 *                             block), proves it can use it, then reads the victim's page (must fault)
 * An attacker that survives its attack prints "isotest: LEAK ...": the test fails on that line. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "nimix_abi.h"

#define MAGIC   0x4E494D4958495351ull
#define OFFSET  0x300000u                 /* 3 MB into the 4 MB region: heap area, unused by the loader */
#define REGION  (4u * 1024 * 1024)

static uintptr_t my_region(void) { int x; return ((uintptr_t)&x) & ~(uintptr_t)(REGION - 1); }

int main(int argc, char **argv) {
    if (argc < 2) { printf("isotest: usage\n"); return 2; }
    volatile uint64_t *mine = (volatile uint64_t *)(my_region() + OFFSET);

    if (!strcmp(argv[1], "victim")) {
        *mine = MAGIC;
        int h = nimixBufCreate(4096);                         /* the first buffer: arena block 0 */
        volatile uint64_t *buf = h > 0 ? (volatile uint64_t *)nimixBufMap((unsigned)h) : NULL;
        if (buf) *buf = MAGIC;
        printf("victim: planted region=%p buffer=%p\n", (void *)mine, (void *)buf);
        struct timespec { long long s; long ns; };
        nimixSleep(500);                                      /* 5 s while the attackers try */
        int ok = *mine == MAGIC && (!buf || *buf == MAGIC);
        printf(ok ? "victim: intact\n" : "victim: CORRUPTED\n");
        return ok ? 0 : 1;
    }
    if (!strcmp(argv[1], "own")) {
        *mine = 1234;
        int h = nimixBufCreate(4096);
        volatile uint64_t *buf = h > 0 ? (volatile uint64_t *)nimixBufMap((unsigned)h) : NULL;
        if (buf) *buf = 99;
        printf((*mine == 1234 && buf && *buf == 99) ? "isotest: own region and buffer ok\n"
                                                    : "isotest: own memory NOT usable\n");
        return 0;
    }
    if (argc >= 3 && (!strcmp(argv[1], "read") || !strcmp(argv[1], "write"))) {
        volatile uint64_t *target = (volatile uint64_t *)(uintptr_t)strtoull(argv[2], NULL, 16);
        printf("isotest: attacker %s %p\n", argv[1], (void *)target);
        if (!strcmp(argv[1], "read")) {
            uint64_t v = *target;
            printf("isotest: LEAK read %llx\n", (unsigned long long)v);
        } else {
            *target = 0xBADBADBADull;
            printf("isotest: LEAK wrote\n");
        }
        return 3;
    }
    if (argc >= 3 && !strcmp(argv[1], "neighbor")) {
        volatile uint64_t *target = (volatile uint64_t *)(uintptr_t)strtoull(argv[2], NULL, 16);
        int h = nimixBufCreate(4096);
        volatile uint64_t *buf = h > 0 ? (volatile uint64_t *)nimixBufMap((unsigned)h) : NULL;
        if (!buf) { printf("isotest: neighbor could not get a buffer\n"); return 2; }
        *buf = 77;
        printf("isotest: neighbor owns %p (%s), victim page %p\n", (void *)buf,
               *buf == 77 ? "usable" : "NOT usable",
               (void *)target);
        uint64_t v = *target;
        printf("isotest: LEAK read %llx\n", (unsigned long long)v);
        return 3;
    }
    printf("isotest: bad arguments\n");
    return 2;
}
