#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Build the NimixOS view of raylib's source tree (V5b): PLATFORM_NIMIX.

raylib selects its platform with `#include "platforms/rcore_memory.c"`, and a
quoted include looks in the including file's own directory first, so a platform
cannot be swapped in from outside. Rather than vendor a modified copy of
raylib's file, this generates the overlay from the pinned original with exact
substitutions: every one must match EXACTLY ONCE, so a raylib bump that moves
the text fails loudly here instead of silently building the wrong thing.

  build/raylib-nimix/src/            symlinks to every file of vendor/raylib/src ...
  build/raylib-nimix/src/platforms/  ... except rcore_memory.c, which is generated:
                                     the memory platform (rlsw renders into RAM)
                                     plus the NimixOS display ABI.

What changes, relative to the memory platform:
  - the framebuffer lives in an OWNED arena buffer (nimixBufCreate), not malloc,
    because the display ABI presents from a buffer the caller owns;
  - SwapScreenBuffer reads rlsw's framebuffer (bytes B,G,R,A in raylib 6.2: already the
    display's B8G8R8X8, see the comment there) and calls nimixDisplayPresent: one
    kernel call per frame;
  - SetWindowPosition places the window on the display;
  - the terminal-polling input (termios/fcntl) is dropped; input arrives from the
    event bus (V5c).
Usage: tools/raylib_nimix.py [repo_root]
"""
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
src = root / "vendor/raylib/src"
out = root / "build/raylib-nimix/src"


def sub_once(text, old, new, what):
    n = text.count(old)
    if n != 1:
        sys.exit(f"raylib_nimix: '{what}' matched {n} times (a raylib update moved it?)")
    return text.replace(old, new, 1)


def adapt(text):
    text = sub_once(text, '''#if defined(_WIN32)
    #include <conio.h>              // Required for: kbhit()
#else
    // Provide kbhit() function in non-Windows platforms
    #include <termios.h>
    #include <unistd.h>
    #include <fcntl.h>
#endif
''', '''// NimixOS: the display ABI (docs/proposals/display_abi.md) and owned buffers.
#include "nimix_abi.h"
''', "include block")

    text = sub_once(text, '''typedef struct {
    unsigned int *pixels;   // Pointer to pixel data buffer (RGBA8888 format)
''', '''typedef struct {
    unsigned int *pixels;   // Pointer to pixel data buffer (RGBA8888 format; B8G8R8X8 once swizzled)
    unsigned int bufHandle; // NimixOS: the owned buffer pixels live in (what nimixDisplayPresent reads)
    int posX, posY;         // NimixOS: where the window sits on the display
''', "PlatformData")

    text = sub_once(text, '''#if !defined(_WIN32)
static int kbhit(void);                         // Check if key has been pressed
static char getch(void) { return getchar(); }   // Get pressed character
#endif
''', '', "kbhit declarations")

    text = sub_once(text, '''    // Update framebuffer
    rlCopyFramebuffer(0, 0, CORE.Window.render.width, CORE.Window.render.height, PIXELFORMAT_UNCOMPRESSED_R8G8B8A8, platform.pixels);
''', '''    // rlsw's colour buffer. NOTE: in raylib 6.2 a PIXELFORMAT_UNCOMPRESSED_R8G8B8A8
    // readback actually delivers the bytes B, G, R, A (red and blue swapped: the same
    // upstream quirk as LoadImageFromScreen). That is exactly the display's native
    // B8G8R8X8, so the bytes go straight to the display ABI with no conversion.
    // tests/qemu_devices.py (display-colours) asserts real colours on screen, so if
    // upstream fixes the readback this FAILS LOUDLY and the swap belongs here.
    int w = CORE.Window.render.width, h = CORE.Window.render.height;
    rlCopyFramebuffer(0, 0, w, h, PIXELFORMAT_UNCOMPRESSED_R8G8B8A8, platform.pixels);

    // One kernel call per frame. The first successful present makes this task the
    // display owner (the kernel console steps aside until we exit).
    NimixPresent req = { sizeof(NimixPresent), platform.bufHandle, (unsigned int)w*4u, 0, 0, w, h, platform.posX, platform.posY };
    if (nimixDisplayPresent(&req) != 0) TRACELOG(LOG_WARNING, "DISPLAY: present refused (display busy or bad request)");
''', "SwapScreenBuffer body")

    text = sub_once(text, '''    TRACELOG(LOG_WARNING, "SetWindowPosition() not available on target platform");
''', '''    platform.posX = (x < 0)? 0 : x;
    platform.posY = (y < 0)? 0 : y;
''', "SetWindowPosition body")

    text = sub_once(text, '''
    // Check for key pressed to exit
    if (kbhit())
    {
        int key = getch();
        if (key == 27) CORE.Window.shouldClose = true; // KEY_ESCAPE
    }
''', '''
    // NimixOS: keys arrive from the event bus (V5c); nothing is polled from a terminal.
''', "PollInputEvents terminal polling")

    text = sub_once(text, '''        // Load memory framebuffer with desired screen size
        platform.pixels = (unsigned int *)RL_CALLOC(CORE.Window.screen.width*CORE.Window.screen.height, sizeof(int));
''', '''        // NimixOS: how big is the display, and a framebuffer the display ABI can read:
        // an owned arena buffer (a task may present only memory it owns).
        NimixDisplayInfo info = { sizeof(NimixDisplayInfo), 0, 0, 0, 0 };
        if (nimixDisplayInfo(&info) != 0 || info.format != NIMIX_DISPLAY_FORMAT_B8G8R8X8)
        {
            TRACELOG(LOG_FATAL, "PLATFORM: no usable display (nimixDisplayInfo)");
            return -1;
        }
        CORE.Window.display.width = (int)info.width;
        CORE.Window.display.height = (int)info.height;
        if (CORE.Window.screen.width > (int)info.width || CORE.Window.screen.height > (int)info.height)
        {
            TRACELOG(LOG_FATAL, "PLATFORM: window %ix%i is larger than the %ux%u display",
                     CORE.Window.screen.width, CORE.Window.screen.height, info.width, info.height);
            return -1;
        }
        int handle = nimixBufCreate(CORE.Window.screen.width*CORE.Window.screen.height*4);
        platform.pixels = (handle > 0)? (unsigned int *)nimixBufMap((unsigned int)handle) : NULL;
        if (platform.pixels == NULL)
        {
            TRACELOG(LOG_FATAL, "PLATFORM: no memory for the framebuffer (nimixBufCreate)");
            return -1;
        }
        platform.bufHandle = (unsigned int)handle;
''', "framebuffer allocation")

    text = sub_once(text, '''    RL_FREE(platform.pixels);
''', '''    nimixBufClose(platform.bufHandle);
    platform.pixels = NULL;
''', "ClosePlatform")

    start = text.index('#if !defined(_WIN32)\n// Check if key has been pressed\nstatic int kbhit(void)')
    end = text.index('#endif\n', start) + len('#endif\n')
    text = text[:start] + text[end:]
    return ("// GENERATED by tools/raylib_nimix.py from vendor/raylib/src/platforms/rcore_memory.c\n"
            "// (PLATFORM_NIMIX: the memory platform + the NimixOS display ABI). Do not edit.\n") + text


def main():
    if out.exists():                       # a generated tree of symlinks and one file
        for dirpath, dirnames, filenames in os.walk(out, topdown=False):
            for f in filenames:
                os.unlink(os.path.join(dirpath, f))
            for d in dirnames:
                p = os.path.join(dirpath, d)
                os.rmdir(p) if not os.path.islink(p) else os.unlink(p)
    (out / "platforms").mkdir(parents=True)
    for entry in sorted(os.listdir(src)):
        if entry == "platforms":
            continue
        os.symlink(src / entry, out / entry)
    for entry in sorted(os.listdir(src / "platforms")):
        if entry != "rcore_memory.c":
            os.symlink(src / "platforms" / entry, out / "platforms" / entry)
    original = (src / "platforms/rcore_memory.c").read_text()
    (out / "platforms/rcore_memory.c").write_text(adapt(original))
    print(f"raylib_nimix: wrote {out.relative_to(root)} (PLATFORM_NIMIX over rcore_memory.c)")


main()
