/* SPDX-License-Identifier: GPL-2.0
 * libnimix part 2 of 3: time. clock_gettime and gettimeofday read the kernel's
 * time page with the program's own rdtsc (no syscall); nanosleep sleeps whole
 * PIT ticks and finishes the last stretch precisely. */
#include <errno.h>
#include <stdint.h>
#include <time.h>
#include <sys/time.h>
#include "nimix_abi.h"
#include "nimix_internal.h"
#include "nimix_timepage.h"

#define NS_PER_SEC 1000000000ull
#define NS_PER_TICK 10000000ull          /* the PIT runs at 100 Hz */

unsigned long long nimix_now_ns(void) {
    const NimixTimePage *p = (const NimixTimePage *)NIMIX_TIME_PAGE_ADDR;
    if (nimix_timepage_valid(p)) return nimix_timepage_nanos(p, nimix_rdtsc());
    return nimixUptimeSecs() * NS_PER_SEC;     /* coarse fallback: no usable TSC clock */
}

/* Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's algorithm). */
static int64_t days_from_civil(int64_t y, unsigned m, unsigned d) {
    y -= m <= 2;
    int64_t era = (y >= 0 ? y : y - 399) / 400;
    unsigned yoe = (unsigned)(y - era * 400);
    unsigned doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + (int64_t)doe - 719468;
}

static int two(const char *s) { return (s[0] - '0') * 10 + (s[1] - '0'); }

/* Wall-clock offset: the RTC says the date (to the second) once; after that the
 * monotonic clock advances it. offset = RTC epoch seconds*1e9 - monotonic now. */
static int64_t wall_offset_ns;
static int     wall_known;

static int wall_init(void) {
    char buf[32];
    if (nimixWallClock(buf, sizeof buf) < 19) return -1;     /* "YYYY-MM-DD HH:MM:SS\n" */
    int64_t year = two(buf) * 100 + two(buf + 2);
    int64_t days = days_from_civil(year, (unsigned)two(buf + 5), (unsigned)two(buf + 8));
    int64_t secs = days * 86400 + two(buf + 11) * 3600 + two(buf + 14) * 60 + two(buf + 17);
    wall_offset_ns = secs * (int64_t)NS_PER_SEC - (int64_t)nimix_now_ns();
    wall_known = 1;
    return 0;
}

int clock_gettime(clockid_t id, struct timespec *ts) {
    int64_t ns;
    if (id == CLOCK_MONOTONIC) {
        ns = (int64_t)nimix_now_ns();
    } else if (id == CLOCK_REALTIME) {
        if (!wall_known && wall_init() != 0) { errno = EIO; return -1; }
        ns = wall_offset_ns + (int64_t)nimix_now_ns();
    } else {
        errno = EINVAL;
        return -1;
    }
    ts->tv_sec = ns / (int64_t)NS_PER_SEC;
    ts->tv_nsec = ns % (int64_t)NS_PER_SEC;
    return 0;
}

int gettimeofday(struct timeval *tv, void *tz) {
    (void)tz;
    struct timespec ts;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0) return -1;
    tv->tv_sec = ts.tv_sec;
    tv->tv_usec = ts.tv_nsec / 1000;
    return 0;
}

/* A tick-based sleep ends on a tick edge, anywhere within one tick of the
 * request: sleep all but the last two ticks, then yield in a loop until the
 * moment. The sleep never ends EARLY (the clock decides), but yielding only
 * returns on the scheduler's tick, so it can end up to one tick (10 ms) late.
 * Sub-tick precision needs a one-shot timer (LAPIC/TSC-deadline): not built. */
int nanosleep(const struct timespec *req, struct timespec *rem) {
    if (rem) { rem->tv_sec = 0; rem->tv_nsec = 0; }
    if (req->tv_sec < 0 || req->tv_nsec < 0 || req->tv_nsec >= (long)NS_PER_SEC) {
        errno = EINVAL;
        return -1;
    }
    unsigned long long ns = (unsigned long long)req->tv_sec * NS_PER_SEC + (unsigned long long)req->tv_nsec;
    unsigned long long target = nimix_now_ns() + ns;
    unsigned long long ticks = ns / NS_PER_TICK;
    if (ticks > 2) nimixSleep(ticks - 2);
    while (nimix_now_ns() < target) nimixYield();
    return 0;
}
