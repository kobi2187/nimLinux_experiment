/* SPDX-License-Identifier: GPL-2.0
 * The kernel's time page, read from C (V3b). Mirrors core/tsc_clock.nim:
 * TimePage (40 bytes, versioned) at TimePageAddr, user read-only for every task;
 * `nanos = ((tsc - base) * mul) >> shift`. Both sides are pinned by tests:
 * tests/test_tsc_clock.nim (Nim) and tests/libnimix/test_clock.c (this file).
 * No kernel entry: a clock read is an rdtsc and two multiplies. */
#pragma once
#include <stdint.h>

#define NIMIX_TIME_PAGE_ADDR  0xE000000ull          /* 224 MB: right after the buffer arena */
#define NIMIX_TIME_PAGE_MAGIC 0x4D495458494D494Eull /* "NIMIXTIM", little-endian */
#define NIMIX_TIME_PAGE_VERSION 1u

typedef struct __attribute__((packed)) {
    uint64_t magic;
    uint32_t version;
    uint32_t valid;     /* 1: the TSC fields below are usable */
    uint64_t base;
    uint64_t hz;
    uint32_t mul;
    uint32_t shift;
} NimixTimePage;

_Static_assert(sizeof(NimixTimePage) == 40, "TimePage is ABI: 40 bytes");
_Static_assert(__builtin_offsetof(NimixTimePage, version) == 8, "version @8");
_Static_assert(__builtin_offsetof(NimixTimePage, base) == 16, "base @16");
_Static_assert(__builtin_offsetof(NimixTimePage, mul) == 32, "mul @32");
_Static_assert(__builtin_offsetof(NimixTimePage, shift) == 36, "shift @36");

/* 1 if the page describes a usable clock (right magic and version, calibrated,
 * shift in range): the same test as pageClock() in core/tsc_clock.nim. */
static inline int nimix_timepage_valid(const NimixTimePage *p) {
    return p->magic == NIMIX_TIME_PAGE_MAGIC && p->version == NIMIX_TIME_PAGE_VERSION &&
           p->valid == 1 && p->shift >= 1 && p->shift <= 32 && p->mul != 0;
}

/* Nanoseconds since the kernel's calibration, for a TSC reading. 0 before `base`.
 * Exact for any delta whose answer fits 64 bits: the 64x32 product is done in two
 * 32-bit halves (hi << 32 is a multiple of 2^shift, so splitting the shift is lossless). */
static inline uint64_t nimix_timepage_nanos(const NimixTimePage *p, uint64_t tsc) {
    if (tsc <= p->base) return 0;
    uint64_t d = tsc - p->base;
    uint64_t hi = (d >> 32) * p->mul;
    uint64_t lo = (d & 0xFFFFFFFFull) * p->mul;
    return (hi << (32 - p->shift)) + (lo >> p->shift);
}

static inline uint64_t nimix_rdtsc(void) {
    uint32_t lo, hi;
    __asm__ volatile("rdtsc" : "=a"(lo), "=d"(hi));
    return ((uint64_t)hi << 32) | lo;
}
