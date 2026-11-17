/* SPDX-License-Identifier: GPL-2.0
 * spawntest — spawn authority and what a child is given (S3).
 * `spawntest parent` is started by the shell; its manifest (spawntest.mf) asks for `spawn` and
 * `net`, the system policy (system.pol) allows only `spawn`, so the launcher gives it ONE handle:
 * a process handle with the spawn right and nothing else (bootstrap handle + 0).
 *   parent: makes a channel, spawns `spawntest child` giving it ONE end, talks to it through the other,
 *           and checks every way of cheating the grant list is refused
 *   child:  holds exactly the one end it was given; proves it has nothing else: it cannot spawn, and
 *           no other handle value works
 * Failures print "spawntest: FAIL ..."; success prints "spawntest: parent ok" / "spawntest: child ok". */
#include <stdio.h>
#include <string.h>
#include "nimix_abi.h"

static int fails, checks;
static void chk(int ok, const char *what) {
    checks++;
    if (!ok) { fails++; printf("spawntest: FAIL %s\n", what); }
}

static int child(void) {
    const NimixHandle mine = NIMIX_BOOTSTRAP_HANDLE;            /* the one end the parent gave us */
    char buf[64];
    NimixChanInfo info;
    /* wait for the parent's message */
    int got = -1;
    for (int i = 0; i < 400 && got < 0; i++) {
        int s = nimixChanStatus(mine);
        if (s > 0 && (s & 1)) { got = nimixChanRead(mine, buf, sizeof buf - 1, &info) == 0 ? info.n : -1; break; }
        nimixSleep(1);
    }
    chk(got > 0, "the child received the parent's message");
    if (got > 0) { buf[got] = 0; chk(!strcmp(buf, "hello child"), "and it is the right one"); }
    chk(info.badge == 0, "no badge was stamped (the parent set none)");
    /* nothing else exists in this world: every other value is refused */
    for (unsigned i = 1; i < 8; i++)
        chk(nimixChanStatus(NIMIX_BOOTSTRAP_HANDLE + i) < 0, "no second handle");
    chk(nimixChanStatus(0x12345) < 0 && nimixChanStatus(0) < 0, "guessed values are refused");
    /* it cannot start a program: it was given no process handle, and a channel end is not one */
    NimixSpawnReq none = { 0 };
    chk(nimixSpawn(mine, "isotest.elf", "own", &none) == -1, "a channel end is not a process handle");
    chk(nimixSpawn(NIMIX_BOOTSTRAP_HANDLE + 1, "isotest.elf", "own", &none) == -1, "no process handle at all");
    chk(nimixSpawn(0, "isotest.elf", "own", &none) == -1, "the null handle spawns nothing");
    nimixChanWrite(mine, "child done", 10, NULL);
    printf(fails ? "spawntest: child FAILED\n" : "spawntest: child ok\n");
    return fails != 0;
}

static int parent(void) {
    const NimixHandle launcher = NIMIX_BOOTSTRAP_HANDLE;
    /* the policy gave us the spawn right and only that */
    chk(nimixChanStatus(launcher) < 0, "the launcher handle is not a channel");
    chk(nimixChanStatus(NIMIX_BOOTSTRAP_HANDLE + 1) < 0, "the policy-denied grant (net) did not arrive");
    NimixHandle dup = (NimixHandle)nimixHandleDup(launcher, NIMIX_RIGHT_READ);
    chk((int)dup < 0, "the spawn right cannot be duplicated (the policy granted it without that right)");

    NimixChanPair p = { sizeof p, 0, 0, 0, 0, 0, 0, 0 };
    chk(nimixChanPair(&p) == 0, "make a channel");
    NimixSpawnReq r;
    memset(&r, 0, sizeof r);

    /* every way of cheating the grant list is refused, and refusing changes nothing */
    r.n = 1; r.handle[0] = 0x12345; r.rights[0] = NIMIX_RIGHT_READ;
    chk(nimixSpawn(launcher, "spawntest.elf", "child", &r) == -1, "a forged handle cannot be granted");
    r.handle[0] = p.h1; r.rights[0] = 0x1FFu;
    chk(nimixSpawn(launcher, "spawntest.elf", "child", &r) == -1, "rights cannot be widened");
    r.n = 2; r.handle[0] = p.h1; r.handle[1] = p.h1; r.rights[0] = r.rights[1] = NIMIX_RIGHT_READ;
    chk(nimixSpawn(launcher, "spawntest.elf", "child", &r) == -1, "one handle cannot be granted twice");
    r.n = 1; r.handle[0] = launcher; r.rights[0] = 0x100u;
    chk(nimixSpawn(launcher, "spawntest.elf", "child", &r) == -1, "the spawn right was given without the right to pass it on");
    r.n = 9;
    chk(nimixSpawn(launcher, "spawntest.elf", "child", &r) == -1, "more than the maximum number of grants");
    r.n = 1; r.handle[0] = p.h1; r.rights[0] = NIMIX_RIGHT_READ | NIMIX_RIGHT_WRITE;
    chk(nimixSpawn(0, "spawntest.elf", "child", &r) == -1, "no process handle: no spawn");
    chk(nimixSpawn(p.h0, "spawntest.elf", "child", &r) == -1, "a channel end is not a process handle");
    chk(nimixSpawn(launcher, "nosuchfile.elf", "x", &r) == -30, "no such file");
    chk(nimixSpawn(launcher, "notes.txt", "x", &r) == -31, "not an executable image");
    chk(nimixChanStatus(p.h1) >= 0, "after all the refusals the end is still ours");

    /* the real spawn: the child gets exactly h1: read, write and wait (no transfer, no duplicate) */
    r.n = 1; r.handle[0] = p.h1; r.rights[0] = NIMIX_RIGHT_READ | NIMIX_RIGHT_WRITE | NIMIX_RIGHT_WAIT;
    int pid = nimixSpawn(launcher, "spawntest.elf", "child", &r);
    chk(pid > 0, "spawn the child");
    chk(nimixChanStatus(p.h1) < 0, "the granted end moved out of our table");
    chk(nimixChanWrite(p.h0, "hello child", 11, NULL) == 0, "write to the child");

    /* the child answers, then exits; its end closes with it */
    char buf[64];
    NimixChanInfo info;
    int got = -1;
    for (int i = 0; i < 600 && got < 0; i++) {
        int s = nimixChanStatus(p.h0);
        if (s < 0) break;
        if (s & 1) { got = nimixChanRead(p.h0, buf, sizeof buf - 1, &info) == 0 ? info.n : -1; break; }
        nimixSleep(1);
    }
    chk(got == 10 && !memcmp(buf, "child done", 10), "the child answered");
    for (int i = 0; i < 600 && !(nimixChanStatus(p.h0) & 2); i++) nimixSleep(1);
    chk(nimixChanStatus(p.h0) >= 0 && (nimixChanStatus(p.h0) & 2), "the child's exit closed its end (peer closed)");
    printf(fails ? "spawntest: parent FAILED\n" : "spawntest: parent ok\n");
    return fails != 0;
}

int main(int argc, char **argv) {
    if (argc >= 2 && !strcmp(argv[1], "parent")) return parent();
    if (argc >= 2 && !strcmp(argv[1], "child")) return child();
    printf("spawntest: usage: spawntest parent\n");
    return 2;
}
