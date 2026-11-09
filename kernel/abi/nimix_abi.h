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
