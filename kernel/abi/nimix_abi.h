/* NimixOS App ABI — C header for apps linking against the kernel ABI.
 *
 * Apps compiled with --os:standalone import these four symbols.
 * The kernel provides the implementations via nimix_abi.nim's exportc procs.
 *
 * This header is also used by Nim apps via {.header: "nimix_abi.h".}
 */
#pragma once

#include <stddef.h>

/* Allocate size bytes. Returns NULL on OOM (should kpanic in practice). */
void* nimixAllocRegion(int size);

/* Release memory previously returned by nimixAllocRegion. */
void  nimixFreeRegion(void* p, int size);

/* Write len bytes from buf to app stdout (VGA text + serial). */
void  nimixWrite(const void* buf, int len);

/* Terminate the calling app. Never returns. */
__attribute__((noreturn)) void nimixExit(int code);

/* Allocate anonymous memory from the app's region heap. Returns NULL on failure. */
void* nimixMapAnon(int size);
/* Release memory (no-op for bump allocator; region freed on nimixExit). */
void  nimixFreeAnon(void* p, int size);

/* ── The rest of the ABI (the kernel patches each weak stub in nimix_abi_stub.c
 *    into a syscall when it loads the ELF). C programs use these through
 *    libnimix/; Nim apps declare the ones they need with importc. ─────────── */

/* Copy the app's argument string (the shell's command tail) into buf; bytes, or <0. */
int   nimixGetArgs(void* buf, int len);
/* Sleep for `ticks` PIT ticks (100 Hz: 10 ms each). Wakes on a tick edge. */
void  nimixSleep(unsigned long long ticks);
/* Give up the CPU until the scheduler runs this task again. */
void  nimixYield(void);
/* Whole seconds since boot. (The fine clock is the time page: libnimix/nimix_timepage.h.) */
unsigned long long nimixUptimeSecs(void);
/* "YYYY-MM-DD HH:MM:SS\n" from the RTC into buf (>= 20 bytes); bytes, or <0. */
int   nimixWallClock(void* buf, int len);
/* Whole-file access by path through the VFS (the interim, ambient-path ABI that
 * fs_server will replace with lent buffers, BACKLOG B10).
 * Read: bytes read (the whole file, never partial); -2 if the file exists but
 * is larger than len (retry with more room); -1 for any other failure.
 * Write: 0 or <0.
 * ReadDir: one "name\n" or "[DIR] name\n" line per entry; bytes, or <0. */
int   nimixFsRead(const char* path, void* buf, int len);
int   nimixFsWrite(const char* path, const void* buf, int len);
int   nimixFsReadDir(const char* path, void* buf, int len);
/* Owned buffers (ipc/buffers): memory a task owns, with a budget, page-enforced.
 * Create returns a handle (>0) or <0; Map returns the address or NULL. */
int   nimixBufCreate(int size);
void* nimixBufMap(unsigned int handle);
int   nimixBufClose(unsigned int handle);
int   nimixBufSeal(unsigned int handle);
int   nimixBufReturn(unsigned int handle);

/* ── Display ABI v1 (docs/proposals/display_abi.md) ────────────────────────────
 * Show a rectangle of a buffer you own on the screen. The kernel reads your
 * buffer only through the ownership store and checks every rectangle; you do any
 * pixel conversion. The first successful present makes you the display owner (the
 * kernel console stops painting); it returns when you exit.
 * Returns 0; -1 bad request; -2 another task owns the display; -3 no display. */
#define NIMIX_DISPLAY_FORMAT_B8G8R8X8 1       /* little-endian 32-bit pixels: B, G, R, unused */

typedef struct { unsigned size, width, height, format, stride_bytes; } NimixDisplayInfo;
typedef struct {
    unsigned size;          /* sizeof(NimixPresent) */
    unsigned handle;        /* an owned or sealed buffer you can read */
    unsigned stride_bytes;  /* bytes per row of that buffer */
    int sx, sy, w, h;       /* the rectangle in the buffer */
    int dx, dy;             /* where it lands on the display */
} NimixPresent;

int nimixDisplayInfo(NimixDisplayInfo* out);          /* the CURRENT mode */
int nimixDisplayPresent(const NimixPresent* req);

/* ── Display ABI v2: modes ─────────────────────────────────────────────────────
 * The boot console runs in the boot mode; a graphics program picks its own.
 * nimixDisplayModes writes up to `max` entries and returns how many modes exist
 * (ascending by size; call with max = 0 to count). nimixDisplaySetMode switches to one of
 * them: like a present it makes you the display owner, and the screen is cleared.
 * nimixDisplayInfo then reports the new size. When the owner ends, the kernel restores
 * the boot mode and repaints the console. Modes larger than the boot mode are not offered.
 * SetMode returns 0; -1 not a listed mode; -2 another task owns the display; -3 no display. */
typedef struct { unsigned width, height; } NimixDisplayMode;
int nimixDisplayModes(NimixDisplayMode* out, int max);
int nimixDisplaySetMode(unsigned width, unsigned height);

/* ── Handles and channels (docs/proposals/capabilities.md) ─────────────────────
 * A handle is an entry in YOUR OWN table; its value means nothing to any other task. You hold
 * only what you were given at spawn or received in a message; there is no way to name anything
 * else. Rights can only be narrowed. A message carries bytes (<= 256) and up to 4 handles, which
 * MOVE. The receiver sees the BADGE of the handle the message was written through, set by whoever
 * issued that handle: it identifies the session and cannot be forged by the sender.
 * Errors are negative: -1 bad handle or argument, -2 wrong kind of object, -3 missing right,
 * -4 would widen rights, -5 peer closed, -6 queue full, -7 empty, -8 too big (info.n = needed),
 * -9 too many handles, -10 a channel end cannot ride its own channel, -11 handle table full,
 * -12 no channel left, -13 no object left. */
typedef unsigned NimixHandle;                       /* 0 = none */
#define NIMIX_BOOTSTRAP_HANDLE 0x10001u             /* the first handle your spawner gave you */
#define NIMIX_RIGHT_READ      1u
#define NIMIX_RIGHT_WRITE     2u
#define NIMIX_RIGHT_TRANSFER  8u                    /* may be sent in a message */
#define NIMIX_RIGHT_DUPLICATE 16u
#define NIMIX_RIGHT_WAIT      32u
#define NIMIX_RIGHTS_CHANNEL  (1u | 2u | 8u | 16u | 32u)

typedef struct {
    unsigned size, rights0, rights1, pad;           /* rights 0 = the channel default */
    unsigned long long badge0, badge1;              /* what the OTHER side sees through h0 / h1 */
    NimixHandle h0, h1;                             /* out */
} NimixChanPair;
typedef struct { NimixHandle handle; unsigned rights; } NimixSendEnt;
typedef struct { unsigned n; NimixSendEnt ent[4]; } NimixSendList;
typedef struct { int n; unsigned nGot; unsigned long long badge; NimixHandle got[4]; } NimixChanInfo;

int nimixChanPair(NimixChanPair* req);
int nimixChanWrite(NimixHandle h, const void* data, int len, const NimixSendList* send);
int nimixChanRead(NimixHandle h, void* buf, int cap, NimixChanInfo* info);
int nimixHandleClose(NimixHandle h);
int nimixHandleDup(NimixHandle h, unsigned rights);    /* the new handle, or < 0 */
int nimixChanStatus(NimixHandle h);                    /* bit 0 readable, bit 1 peer closed */
