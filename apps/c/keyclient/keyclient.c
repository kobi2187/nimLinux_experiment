/* SPDX-License-Identifier: GPL-2.0
 * keyclient — the legitimate client of the input port (K3). Its manifest says `grant input`, so the
 * launcher moves the shell's port handle to it at spawn. It reads typed events and prints each one, and
 * exits when it sees the 'q' key (evdev 16) go down, or after about 6 seconds with nothing.
 * Used by the shell's `keytest`, which feeds events through the same path the virtio driver uses. */
#include <stdio.h>
#include "nimix_abi.h"
#include "nimix_input.h"

int main(void) {
    NimixHandle port = nimix_find_port(NIMIX_PORT_INPUT);
    if (!port) { printf("keyclient: no input port\n"); return 1; }
    printf("keyclient: have the input port\n");
    int idle = 0;
    for (;;) {
        NimixInputEvent ev;
        int r = nimix_input_next(port, &ev);
        if (r < 0) { printf("keyclient: read error %d\n", r); return 1; }
        if (r == 0) {                                    /* nothing waiting: block until an event or the timeout */
            NimixWaitItem w = { port, 0 };
            if (nimixWait(&w, 1, 100) == 0 && ++idle >= 6) { printf("keyclient: timed out\n"); return 2; }
            continue;
        }
        idle = 0;
        switch (ev.kind) {
        case NIMIX_IN_KEY:    printf("keyclient: key %u %d\n", ev.code, ev.value); break;
        case NIMIX_IN_MOTION: printf("keyclient: motion %d %d %s\n", ev.x, ev.y, ev.absolute ? "abs" : "rel"); break;
        case NIMIX_IN_BUTTON: printf("keyclient: button %u %d\n", ev.code, ev.value); break;
        case NIMIX_IN_WHEEL:  printf("keyclient: wheel %d %d\n", ev.x, ev.y); break;
        case NIMIX_IN_LOST:   printf("keyclient: lost %d\n", ev.value); break;
        }
        if (ev.kind == NIMIX_IN_KEY && ev.code == 16 && ev.value == 1) { printf("keyclient: done\n"); return 0; }
    }
}
