/* SPDX-License-Identifier: GPL-2.0
 * chantest — handles and channels from ring 3 (docs/proposals/capabilities.md).
 * Started by the shell's `chantest` command, which gives this program ONE handle, the bootstrap
 * channel end (NIMIX_BOOTSTRAP_HANDLE), badge 77 on this side. Everything else this program can
 * touch arrives through it or is created here. It then:
 *   1. reads "hello"; writes "ping" (the shell must see badge 77: set by whoever issued our handle)
 *   2. is told two handle VALUES the shell holds and we do not, and tries every operation on them,
 *      on forged values, and on misuses of its own handles: all must be refused
 *   3. makes a channel, keeps one end, SENDS the other (it moves: our copy stops working), and reads
 *      what the shell writes through it, stamped with the badge we gave that end (5)
 *   4. reports, and exits (the shell must then see its end report peer-closed) */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>
#include "nimix_abi.h"

static int fails, checks;
static void chk(int ok, const char *what) {
    checks++;
    if (!ok) { fails++; printf("chantest: FAIL %s\n", what); }
}

static long long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int wait_readable(NimixHandle h) {                /* 1 readable, 0 timeout, -1 peer closed */
    for (int i = 0; i < 500; i++) {
        int s = nimixChanStatus(h);
        if (s < 0) return -1;
        if (s & 1) return 1;
        if (s & 2) return -1;
        nimixSleep(1);
    }
    return 0;
}

static int recv_msg(NimixHandle h, char *buf, int cap, NimixChanInfo *info) {
    if (wait_readable(h) != 1) return -100;
    return nimixChanRead(h, buf, cap, info);
}

int main(void) {
    char buf[300];
    NimixChanInfo info;
    printf("chantest: start\n");
    const NimixHandle boot = NIMIX_BOOTSTRAP_HANDLE;

    /* 0. blocking wait: nothing has been written yet, so a short wait must time out, and a long one
     *    must be ended by the shell's write (about a second later), not by its own timeout */
    NimixWaitItem w = { boot, 0xdead };
    long long t0 = now_ms();
    int nw = nimixWait(&w, 1, 20);
    long long dt = now_ms() - t0;
    chk(nw == 0 && w.ready == 0, "a wait with nothing to read times out and reports 0");
    chk(dt >= 150 && dt <= 600, "and takes about the timeout (20 ticks = 200 ms)");
    printf("chantest: timeout wait took %lld ms\n", dt);
    t0 = now_ms();
    nw = nimixWait(&w, 1, 800);                          /* 8 s: only a write ends it early */
    dt = now_ms() - t0;
    chk(nw == 1 && (w.ready & 1) && !(w.ready & 2), "a write wakes the waiter with the end readable");
    chk(dt < 5000, "woken by the write, not by the timeout");
    printf("chantest: blocking wait took %lld ms\n", dt);
    /* misuse of wait */
    NimixWaitItem bad[9];
    for (int i = 0; i < 9; i++) { bad[i].handle = boot; bad[i].ready = 0; }
    chk(nimixWait(bad, 0, 5) < 0, "wait on no handles");
    chk(nimixWait(bad, 9, 5) < 0, "wait on too many handles");
    chk(nimixWait(NULL, 1, 5) < 0, "wait through a NULL list");
    chk(nimixWait((NimixWaitItem *)0x1000, 1, 5) < 0, "wait through a kernel pointer");
    NimixWaitItem forged = { 0x7777u, 0 };
    chk(nimixWait(&forged, 1, 5) < 0, "wait on a handle we do not hold");
    NimixWaitItem mixed[2] = { { boot, 0 }, { 0x7777u, 0 } };
    chk(nimixWait(mixed, 2, 5) < 0, "one bad handle refuses the whole wait");
    int rd = nimixHandleDup(boot, NIMIX_RIGHT_READ);     /* no wait right */
    NimixWaitItem nowait = { (unsigned)rd, 0 };
    chk(rd > 0 && nimixWait(&nowait, 1, 5) < 0, "waiting needs the wait right");
    nimixHandleClose((unsigned)rd);

    /* 1. hello / ping */
    int r = recv_msg(boot, buf, sizeof buf, &info);
    chk(r == 0 && info.n == 5 && !memcmp(buf, "hello", 5), "read hello");
    chk(r == 0 && info.badge == 0, "the shell's end has badge 0");
    chk(nimixChanWrite(boot, "ping", 4, NULL) == 0, "write ping");

    /* 2. foreign and forged handles */
    r = recv_msg(boot, buf, sizeof buf - 1, &info);
    buf[r == 0 ? info.n : 0] = 0;
    unsigned fa = 0, fb = 0;
    chk(r == 0 && sscanf(buf, "foreign:%u %u", &fa, &fb) == 2, "read the foreign values");
    chk(fa != boot && fb != boot, "the shell's decoys are not our bootstrap");
    unsigned foreign[] = { fa, fb, 0, 0xFFFFFFFFu, 0x10000u, 0x10002u, 0x20001u, 0x7FFF0001u };
    for (unsigned i = 0; i < sizeof foreign / sizeof foreign[0]; i++) {
        unsigned v = foreign[i];
        if (v == boot) continue;
        chk(nimixChanWrite(v, "x", 1, NULL) < 0, "write through a handle we do not hold");
        chk(nimixChanRead(v, buf, sizeof buf, &info) < 0, "read through a handle we do not hold");
        chk(nimixChanStatus(v) < 0, "status of a handle we do not hold");
        chk(nimixHandleDup(v, NIMIX_RIGHT_READ) < 0, "duplicate a handle we do not hold");
        chk(nimixHandleClose(v) < 0, "close a handle we do not hold");
    }
    /* rights only narrow */
    int ro = nimixHandleDup(boot, NIMIX_RIGHT_READ);
    chk(ro > 0, "duplicate with fewer rights");
    chk(nimixChanWrite((unsigned)ro, "x", 1, NULL) == -3, "a read-only duplicate cannot write");
    chk(nimixHandleDup((unsigned)ro, NIMIX_RIGHT_READ) == -3, "a duplicate without the duplicate right cannot duplicate");
    chk(nimixHandleDup(boot, 4u /* MAP: the bootstrap lacks it */) == -4, "rights cannot widen");
    chk(nimixHandleClose((unsigned)ro) == 0, "close the duplicate");
    chk(nimixHandleClose((unsigned)ro) < 0, "a closed handle is stale");
    chk(nimixChanStatus((unsigned)ro) < 0, "and stays dead");
    /* misuse of messages */
    NimixSendList self = { 1, { { boot, NIMIX_RIGHTS_CHANNEL } } };
    chk(nimixChanWrite(boot, "x", 1, &self) == -10, "an end cannot ride its own channel");
    NimixSendList many = { 5, { { boot, 1 } } };
    chk(nimixChanWrite(boot, "x", 1, &many) == -9, "too many handles");
    static char big[257];
    chk(nimixChanWrite(boot, big, 257, NULL) == -8, "message too big");
    chk(nimixChanWrite(boot, big, -1, NULL) < 0, "negative length");
    chk(nimixChanRead(boot, big, -1, &info) < 0, "negative capacity");
    chk(nimixChanWrite(boot, (void *)0x1000, 8, NULL) < 0, "data in kernel memory");
    chk(nimixChanRead(boot, (void *)0x1000, 8, &info) < 0, "buffer in kernel memory");
    chk(nimixChanPair((NimixChanPair *)0x1000) < 0, "request in kernel memory");

    /* 3. our own channel: keep x, send y */
    NimixChanPair p = { sizeof p, 0, 0, 0, 0 /* badge for x's peer side */, 5 /* y is stamped 5 */, 0, 0 };
    chk(nimixChanPair(&p) == 0 && p.h0 && p.h1 && p.h0 != p.h1, "create a channel");
    NimixSendList give = { 1, { { p.h1, NIMIX_RIGHTS_CHANNEL } } };
    chk(nimixChanWrite(boot, "here is y", 9, &give) == 0, "send y");
    chk(nimixChanWrite(p.h1, "x", 1, NULL) < 0, "y has moved: our copy is dead");
    chk(nimixChanStatus(p.h1) < 0, "and stays dead");
    r = recv_msg(p.h0, buf, sizeof buf - 1, &info);
    buf[r == 0 ? info.n : 0] = 0;
    chk(r == 0 && !strcmp(buf, "via y"), "the shell wrote to us through the end we sent");
    chk(r == 0 && info.badge == 5, "stamped with the badge we gave y");

    /* 3b. a peer that closes wakes a waiter: the shell sent us one end of a channel and will close
     *     the other after a moment */
    r = recv_msg(boot, buf, sizeof buf - 1, &info);
    chk(r == 0 && info.n == 6 && !memcmp(buf, "closer", 6) && info.nGot == 1, "receive the closer end");
    if (r == 0 && info.nGot == 1) {
        NimixWaitItem cw = { info.got[0], 0 };
        t0 = now_ms();
        nw = nimixWait(&cw, 1, 800);
        dt = now_ms() - t0;
        chk(nw == 1 && (cw.ready & 2), "the peer's close wakes the waiter with bit 1 (peer closed)");
        chk(dt < 5000, "woken by the close, not the timeout");
        printf("chantest: close wait took %lld ms\n", dt);
    }

    /* 4. report */
    char rep[40];
    int len = snprintf(rep, sizeof rep, "hostile:%d/%d", fails, checks);
    chk(nimixChanWrite(boot, rep, len, NULL) == 0, "report");
    printf("chantest: %d checks, %d failed\n", checks, fails);
    if (!fails) printf("chantest: ok\n");
    return fails ? 1 : 0;
}
