/* SPDX-License-Identifier: GPL-2.0
 * overlay — a malicious program that tries to take over the screen (D3 option A attack test). It has NO
 * manifest, so it holds no display port. It tries every way to draw or change the display: info, modes,
 * setMode and present through the library, a present of a buffer it really owns, and raw port calls on
 * guessed handle values. Every attempt must be refused; any success prints "overlay: LEAK". */
#include <stdio.h>
#include "nimix_abi.h"
#include "nimix_display.h"

int main(void) {
    int leaks = 0;
    NimixDisplayInfo info = { sizeof info, 0, 0, 0, 0 };
    NimixDisplayMode modes[4];
    int h = nimixBufCreate(640 * 400 * 4);                          /* a real buffer it owns: the strongest present */
    NimixPresent q = { sizeof q, (unsigned)h, 640 * 4, 0, 0, 640, 400, 0, 0 };
    if (nimixDisplayInfo(&info) != NIMIX_E_NO_DISPLAY_PORT) { printf("overlay: LEAK displayInfo answered\n"); leaks++; }
    if (nimixDisplayModes(modes, 4) != NIMIX_E_NO_DISPLAY_PORT) { printf("overlay: LEAK displayModes answered\n"); leaks++; }
    if (nimixDisplaySetMode(800, 600) != NIMIX_E_NO_DISPLAY_PORT) { printf("overlay: LEAK setMode accepted\n"); leaks++; }
    if (nimixDisplayPresent(&q) != NIMIX_E_NO_DISPLAY_PORT) { printf("overlay: LEAK present accepted\n"); leaks++; }
    const NimixHandle guesses[] = { NIMIX_BOOTSTRAP_HANDLE, NIMIX_BOOTSTRAP_HANDLE + 1, 0x10002, 0x20001, 1, 0x1ffff };
    for (unsigned i = 0; i < sizeof guesses / sizeof guesses[0]; i++) {
        unsigned char m[NIMIX_PORT_MSG] = { 0 };                    /* a display "present" request, as raw bytes */
        m[2] = 3; m[8] = 32;
        if (nimixPortCall(guesses[i], m, NIMIX_PORT_HEADER + 32, NIMIX_PORT_MSG) >= 0) {
            printf("overlay: LEAK a port call worked on %x\n", guesses[i]); leaks++;
        }
    }
    /* the retired syscalls (37-40) are gone for good: raw numbers refuse too */
    printf(leaks ? "overlay: LEAKED\n" : "overlay: refused\n");
    return leaks != 0;
}
