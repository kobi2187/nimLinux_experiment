/* SPDX-License-Identifier: GPL-2.0
 * keylog — a keylogger that tries every way to read the keyboard (K3 attack test). It has NO manifest, so
 * it is granted nothing. It tries: finding an input port among its handles; reading and waiting on guessed
 * handle values; and the old way, subscribing to the "input" event topic. It watches for about 4 seconds
 * while the shell's `keytest` feeds keys to the legitimate client. Any key it sees prints "keylog: LEAK".
 * Expected: "keylog: got nothing". */
#include <stdio.h>
#include "nimix_abi.h"
#include "nimix_input.h"

int main(void) {
    int leaked = 0;
    NimixHandle port = nimix_find_port(NIMIX_PORT_INPUT);
    if (port) { printf("keylog: LEAK found an input port handle %x\n", port); leaked++; }
    unsigned char m[NIMIX_PORT_MSG];
    const NimixHandle guesses[] = { NIMIX_BOOTSTRAP_HANDLE, NIMIX_BOOTSTRAP_HANDLE + 1, 0x10002, 0x20001, 1, 0x1ffff };
    for (unsigned i = 0; i < sizeof guesses / sizeof guesses[0]; i++) {
        if (nimixPortEvent(guesses[i], m, sizeof m) >= 0) { printf("keylog: LEAK read events through %x\n", guesses[i]); leaked++; }
        NimixWaitItem w = { guesses[i], 0 };
        if (nimixWait(&w, 1, 1) >= 0) { printf("keylog: LEAK waited on %x\n", guesses[i]); leaked++; }
    }
    const char *topics[] = { "input", "key.down", "mouse.move", "mouse.click" };   /* the old way: global topics anyone could read */
    unsigned toks[4];
    for (int i = 0; i < 4; i++) toks[i] = nimixEventSubscribe(topics[i]);
    int seen = 0;
    for (int tick = 0; tick < 40; tick++) {                /* ~4 s */
        unsigned char ev[64];
        for (int i = 0; i < 4; i++)
            while (toks[i] && nimixEventPoll(toks[i], ev, sizeof ev) > 0) seen++;
        nimixSleep(10);
    }
    if (seen) { printf("keylog: LEAK %d events on the old global topics\n", seen); leaked++; }
    printf(leaked ? "keylog: LEAKED\n" : "keylog: got nothing\n");
    return leaked != 0;
}
