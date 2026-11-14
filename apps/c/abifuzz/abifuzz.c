/* SPDX-License-Identifier: GPL-2.0
 * abifuzz — hostile arguments at every syscall, from ring 3.
 * A ring-3 program controls every argument it passes the kernel. This one passes the worst:
 * NULL, kernel addresses, another task's region, the unowned arena, wrapping ranges, negative
 * and enormous sizes, unterminated names, stale handles and tokens. The kernel must refuse each
 * (the call returns -1 / NULL / 0 as documented) and carry on: no panic, no corruption. The
 * harness then checks the shell still answers. Legitimate calls on the program's own memory are
 * mixed in, so a check that refuses too much fails too. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "nimix_abi.h"

/* the parts of the ABI the header leaves to Nim apps (see kernel/abi/nimix_abi_weak.c) */
int   nimixChanSend(const char *name, const void *data, int len);
int   nimixChanRecv(const char *name, void *buf, int len);
void  nimixEventPublish(const char *topic, const void *data, int len);
unsigned int nimixEventSubscribe(const char *topic);
int   nimixEventPoll(unsigned int token, void *buf, int len);
int   nimixProcList(void *buf, int len);
int   nimixSchedStats(void *buf, int len);
int   nimixProcKillPid(unsigned int pid);
int   nimixCapSend(const char *name, unsigned long long tok, const void *data, int len);
int   nimixChanCall(const char *server, const void *data, int dataLen, void *replyBuf, int replyBufLen);
int   nimixSysInfo(void *buf, int len);
unsigned long long nimixGrantRegion(int slot, unsigned int right);
int   nimixSndPlay(const void *pcm, int len);
int   nimixSndDrain(void);
unsigned long long nimixChanCreate(const char *name);
int   nimixCapRecv(unsigned long long tok, void *buf, int len);
int   nimixBufMsgSend(const char *name, const void *data, int len, void *hs);
int   nimixBufMsgRecv(unsigned long long tok, void *buf, int len, void *hs);

static int fails, checks;
static void chk(int ok, const char *what) {
    checks++;
    if (!ok) { fails++; printf("abifuzz: FAIL %s\n", what); }
}
#define NEG(call, what)  chk((call) < 0, what)         /* refused: -1 or another negative error */
#define NIL(call, what)  chk((call) == 0, what)        /* refused: NULL / 0 */

int main(void) {
    static char buf[256];                              /* our own memory: a valid target */
    static char longname[700];                         /* 700 bytes, no NUL: an unterminated name */
    memset(longname, 'a', sizeof longname);
    uintptr_t mine = (uintptr_t)buf & ~(uintptr_t)0x3FFFFF;     /* our 4 MB region slot */
    void *bad[] = { NULL, (void *)0x1000, (void *)0x100000, (void *)(mine + 0x400000), (void *)(mine - 0x400000),
                    (void *)0x6000000 /* the buffer arena's first block: not ours */, (void *)0xFFFFFFFFFFFFFFF0ull,
                    (void *)0x8000000000000000ull };
    const int nbad = (int)(sizeof bad / sizeof bad[0]);
    printf("abifuzz: start\n");

    for (int i = 0; i < nbad; i++) {
        void *p = bad[i];
        nimixWrite(p, 16);                                                 /* void: must not fault the kernel */
        NEG(nimixChanSend("abifuzz", p, 8), "chanSend data");
        NEG(nimixChanSend((const char *)p, "x", 1), "chanSend name");
        NEG(nimixChanRecv("abifuzz", p, 8), "chanRecv buf");
        NEG(nimixChanRecv((const char *)p, buf, 8), "chanRecv name");
        nimixEventPublish("abifuzz", p, 8);
        nimixEventPublish((const char *)p, "x", 1);
        NIL(nimixEventSubscribe((const char *)p), "eventSubscribe name");
        NEG(nimixEventPoll(1, p, 8), "eventPoll buf");
        NEG(nimixGetArgs(p, 64), "getArgs");
        NEG(nimixProcList(p, 64), "procList");
        NEG(nimixSchedStats(p, 64), "schedStats");
        NEG(nimixFsReadDir((const char *)p, buf, 64), "fsReadDir path");
        NEG(nimixFsReadDir("/", p, 64), "fsReadDir buf");
        NEG(nimixFsRead((const char *)p, buf, 64), "fsRead path");
        NEG(nimixFsRead("/NOSUCH.TXT", p, 64), "fsRead buf");
        NEG(nimixFsWrite((const char *)p, buf, 8), "fsWrite path");
        NEG(nimixFsWrite("/FUZZ.TMP", p, 8), "fsWrite buf");
        NEG(nimixCapSend((const char *)p, 1, "x", 1), "capSend name");
        NEG(nimixCapSend("abifuzz", 1, p, 8), "capSend data");
        NEG(nimixChanCall((const char *)p, "x", 1, buf, 8), "chanCall server");
        NEG(nimixChanCall("abifuzz", p, 8, buf, 8), "chanCall data");
        NEG(nimixSysInfo(p, 64), "sysInfo");
        NEG(nimixWallClock(p, 64), "wallClock");
        NEG(nimixSndPlay(p, 64), "sndPlay");
        NIL(nimixChanCreate((const char *)p), "chanCreate name");
        NEG(nimixCapRecv(1, p, 8), "capRecv");
        NEG(nimixBufMsgSend((const char *)p, "x", 1, NULL), "bufMsgSend name");
        NEG(nimixBufMsgSend("abifuzz", p, 8, NULL), "bufMsgSend data");
        NEG(nimixBufMsgSend("abifuzz", "x", 1, p), "bufMsgSend handles");
        NEG(nimixBufMsgRecv(1, p, 8, NULL), "bufMsgRecv buf");
        NEG(nimixBufMsgRecv(1, buf, 8, p), "bufMsgRecv handles");
        NEG(nimixDisplayInfo((NimixDisplayInfo *)p), "displayInfo");
        NEG(nimixDisplayPresent((const NimixPresent *)p), "displayPresent");
        NEG(nimixDisplayModes((NimixDisplayMode *)p, 4), "displayModes");
        NEG(nimixChanPair((NimixChanPair *)p), "chanPair request");
        NEG(nimixChanWrite(NIMIX_BOOTSTRAP_HANDLE, p, 8, NULL), "chanWrite data");
        NEG(nimixChanWrite(NIMIX_BOOTSTRAP_HANDLE, "x", 1, (const NimixSendList *)p), "chanWrite handle list");
        NEG(nimixChanRead(NIMIX_BOOTSTRAP_HANDLE, p, 8, NULL), "chanRead buffer");
        NEG(nimixChanRead(NIMIX_BOOTSTRAP_HANDLE, buf, 8, (NimixChanInfo *)p), "chanRead info");
        nimixFreeRegion(p, 16);                                            /* a value, never dereferenced */
        nimixFreeAnon(p, 16);
    }

    /* unterminated and over-long names */
    NEG(nimixChanSend(longname, "x", 1), "unterminated name (chanSend)");
    NEG(nimixFsRead(longname, buf, 64), "unterminated path (fsRead)");
    NIL(nimixChanCreate(longname), "unterminated name (chanCreate)");

    /* sizes: negative, huge, wrapping */
    static const int sizes[] = { -1, -4096, 0x7FFFFFFF, 0x10000000, (int)0x80000000 };
    for (unsigned i = 0; i < sizeof sizes / sizeof sizes[0]; i++) {
        int n = sizes[i];
        nimixWrite(buf, n);
        NEG(nimixChanSend("abifuzz", buf, n), "chanSend len");
        NEG(nimixChanRecv("abifuzz", buf, n), "chanRecv len");
        NEG(nimixGetArgs(buf, n), "getArgs len");
        NEG(nimixFsRead("/NOSUCH.TXT", buf, n), "fsRead len");
        NEG(nimixFsWrite("/FUZZ.TMP", buf, n), "fsWrite len");
        NEG(nimixSysInfo(buf, n), "sysInfo len");
        NEG(nimixWallClock(buf, n), "wallClock len");
        NEG(nimixSndPlay(buf, n), "sndPlay len");
        NEG(nimixDisplayModes((NimixDisplayMode *)buf, n), "displayModes max");
    }

    /* values that are not pointers */
    NIL(nimixMapAnon(0), "mapAnon(0)");
    NIL(nimixMapAnon(-1), "mapAnon(-1)");
    NIL(nimixMapAnon(0x7FFFFFFF), "mapAnon(2 GB)");
    NIL(nimixAllocRegion(0), "allocRegion(0)");
    NIL(nimixAllocRegion(-1), "allocRegion(-1)");
    NIL(nimixAllocRegion(0x7FFFFFFF), "allocRegion(2 GB)");
    NEG(nimixBufCreate(0), "bufCreate(0)");
    NEG(nimixBufCreate(-1), "bufCreate(-1)");
    NEG(nimixBufCreate(0x7FFFFFFF), "bufCreate(2 GB): over budget");
    NIL(nimixBufMap(0), "bufMap(0)");
    NIL(nimixBufMap(0xFFFFFFFFu), "bufMap(stale)");
    NEG(nimixBufClose(0xFFFFFFFFu), "bufClose(stale)");
    NEG(nimixBufSeal(0xFFFFFFFFu), "bufSeal(stale)");
    NEG(nimixBufReturn(0xFFFFFFFFu), "bufReturn(stale)");
    NIL(nimixGrantRegion(-1, 4), "grantRegion(slot -1)");
    NIL(nimixGrantRegion(99999, 4), "grantRegion(slot 99999)");
    NIL(nimixGrantRegion(0, 99), "grantRegion(right 99)");
    NEG(nimixProcKillPid(0xFFFFFFFFu), "procKillPid(none)");
    NEG(nimixEventPoll(0, buf, 8), "eventPoll(token 0)");
    NEG(nimixEventPoll(0xFFFFFFFFu, buf, 8), "eventPoll(stale token)");
    NEG(nimixCapRecv(0, buf, 8), "capRecv(token 0)");
    NEG(nimixCapRecv(0xDEADBEEFDEADBEEFull, buf, 8), "capRecv(forged token)");
    NEG(nimixCapSend("abifuzz", 0xDEADBEEFDEADBEEFull, "x", 1), "capSend(forged token)");
    NEG(nimixDisplaySetMode(0, 0), "setMode(0,0)");
    NEG(nimixDisplaySetMode(0xFFFFFFFFu, 0xFFFFFFFFu), "setMode(huge)");
    /* handles: this program was started by the shell with none, so every value is foreign */
    NEG(nimixChanWrite(NIMIX_BOOTSTRAP_HANDLE, "x", 1, NULL), "chanWrite with no handle held");
    NEG(nimixChanStatus(0xFFFFFFFFu), "chanStatus(forged)");
    NEG(nimixHandleClose(0), "handleClose(0)");
    NEG(nimixHandleDup(0x10001u, 1), "handleDup(not held)");
    nimixSleep(0);
    nimixYield();

    /* legitimate calls on our own memory must still work: refusing too much is a bug too */
    chk(nimixWallClock(buf, (int)sizeof buf) > 0, "wallClock into our own memory");
    chk(nimixGetArgs(buf, (int)sizeof buf) >= 0, "getArgs into our own memory");
    chk(nimixFsReadDir("/", buf, (int)sizeof buf) > 0, "fsReadDir(/) into our own memory");
    int h = nimixBufCreate(4096);
    char *ap = (char *)nimixBufMap((unsigned)h);
    chk(h > 0 && ap != NULL, "own buffer");
    if (ap) {
        chk(nimixWallClock(ap, 64) > 0, "wallClock into our own arena buffer (writable)");
        nimixWrite(ap, 8);
        chk(nimixBufSeal((unsigned)h) == 0, "seal");
        chk(nimixWallClock(ap, 64) < 0, "wallClock into a SEALED buffer is refused: the kernel would write through a read-only buffer");
        nimixWrite(ap, 8);                                                 /* reading a sealed buffer is fine */
        chk(nimixBufClose((unsigned)h) == 0, "close");
        NEG(nimixWallClock(ap, 64), "wallClock into a buffer we closed");
    }
    chk(nimixChanCreate("abifuzz-chan") != 0, "chanCreate(own name) works (returns a token)");

    printf("abifuzz: %d checks, %d failed\n", checks, fails);
    if (!fails) printf("abifuzz: ok\n");
    return fails ? 1 : 0;
}
