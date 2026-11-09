/* SPDX-License-Identifier: GPL-2.0
 * libnimix runtime: what picolibc needs from the OS to run a C program on
 * NimixOS, part 1 of 3 (see also time.c, fs.c, refused.c).
 *
 *   appMain  the entry the ELF loader calls (it finds the symbol by name)
 *   stdio    stdin/stdout/stderr over nimixWrite; line-buffered, one sink
 *   sbrk     the heap: ONE owned arena buffer (V4: memory is buffers)
 *   _exit    flush and nimixExit
 *
 * Nothing here is ambient: no files are opened implicitly, and the heap is
 * memory this task owns and is budgeted for, not a shared region. */
#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "nimix_abi.h"
#include "nimix_internal.h"

/* ── stdio ───────────────────────────────────────────────────────────────────
 * picolibc's stdio is "tinystdio": a FILE is a few function pointers. Every
 * character printf produces goes through `put`; calling nimixWrite per
 * character would be a syscall per character, so the console sink keeps a
 * line buffer and writes on newline (or when full, flush, exit). stdout and
 * stderr share the one sink so their output stays in order. */
#define CONSOLE_BUF 256
static char console_buf[CONSOLE_BUF];
static int  console_len;

void nimix_console_flush(void) {
    if (console_len) {
        nimixWrite(console_buf, console_len);
        console_len = 0;
    }
}

static int console_put(char c, FILE *f) {
    (void)f;
    console_buf[console_len++] = c;
    if (c == '\n' || console_len == CONSOLE_BUF) nimix_console_flush();
    return (unsigned char)c;
}
static int console_flush_cb(FILE *f) { (void)f; nimix_console_flush(); return 0; }
/* No stdin source exists in the ABI (input arrives as events): always EOF. */
static int stdin_get(FILE *f) { (void)f; return _FDEV_EOF; }

static FILE nimix_stdin  = FDEV_SETUP_STREAM(NULL, stdin_get, NULL, _FDEV_SETUP_READ);
static FILE nimix_stdout = FDEV_SETUP_STREAM(console_put, NULL, console_flush_cb, _FDEV_SETUP_WRITE);
FILE *const stdin  = &nimix_stdin;
FILE *const stdout = &nimix_stdout;
FILE *const stderr = &nimix_stdout;

/* ── exit ────────────────────────────────────────────────────────────────── */
__attribute__((noreturn)) void _exit(int code) {
    nimix_console_flush();
    nimixExit(code);
}

/* ── heap ────────────────────────────────────────────────────────────────────
 * picolibc's malloc grows through sbrk(). Our sbrk hands out one contiguous
 * owned buffer, created on first use. A program that needs more (the render
 * server) builds with -DNIMIX_HEAP_BYTES=... (it must fit the task's buffer
 * budget, 32 MB by default, which also pays for rings and frame buffers). */
#ifndef NIMIX_HEAP_BYTES
#define NIMIX_HEAP_BYTES (16u * 1024 * 1024)
#endif

static char *heap_lo, *heap_cur, *heap_hi;
static int   heap_tried;

void *sbrk(ptrdiff_t incr) {
    if (!heap_tried) {
        heap_tried = 1;
        int h = nimixBufCreate(NIMIX_HEAP_BYTES);
        if (h > 0) {
            heap_lo = nimixBufMap((unsigned)h);
            if (heap_lo) { heap_cur = heap_lo; heap_hi = heap_lo + NIMIX_HEAP_BYTES; }
        }
    }
    if (!heap_lo || (incr > 0 && incr > heap_hi - heap_cur) || (incr < 0 && -incr > heap_cur - heap_lo)) {
        errno = ENOMEM;
        return (void *)-1;
    }
    char *p = heap_cur;
    heap_cur += incr;
    return p;
}

/* ── entry ───────────────────────────────────────────────────────────────────
 * The loader calls appMain (by symbol name) after relocating the image. The
 * argument string is the shell's command tail; split it on spaces. */
extern int main(int argc, char **argv);

#define MAX_ARGS 16
static char  arg_text[256];
static char *arg_vec[MAX_ARGS + 1];

__attribute__((used)) void appMain(void) {
    int argc = 0;
    arg_vec[argc++] = "app";
    int n = nimixGetArgs(arg_text, sizeof arg_text - 1);
    if (n > 0) {
        arg_text[n < (int)sizeof arg_text ? n : (int)sizeof arg_text - 1] = 0;
        for (char *p = arg_text; *p && argc < MAX_ARGS;) {
            while (*p == ' ') *p++ = 0;
            if (!*p) break;
            arg_vec[argc++] = p;
            while (*p && *p != ' ') p++;
        }
    }
    arg_vec[argc] = NULL;
    exit(main(argc, arg_vec));
}
