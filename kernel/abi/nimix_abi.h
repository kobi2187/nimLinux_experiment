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

/* ── The display is a device PORT (docs/proposals/device_ports.md) ──────────────
 * Syscalls 37-40 (nimixDisplayInfo/Present/Modes/SetMode) are retired. A program draws only if its manifest
 * says `grant display` and the system policy allows it: the launcher then moves the display port's handle to
 * it (one holder at a time). libnimix/nimix_display.h provides the same four functions over that handle. */

/* ── Handles and channels (docs/proposals/capabilities.md) ─────────────────────
 * A handle is an entry in YOUR OWN table; its value means nothing to any other task. You hold
 * only what you were given at spawn or received in a message; there is no way to name anything
 * else. Rights can only be narrowed. A message carries bytes (<= 256) and up to 4 handles, which
 * MOVE. The receiver sees the BADGE of the handle the message was written through, set by whoever
 * issued that handle: it identifies the session and cannot be forged by the sender.
 * Errors are negative: -1 bad handle or argument, -2 wrong kind of object, -3 missing right,
 * -4 would widen rights, -5 peer closed, -6 queue full, -7 empty, -8 too big (info.n = needed),
 * -9 too many handles, -10 a channel end cannot ride its own channel, -11 handle table full,
 * -12 no channel left, -13 no object left, -14 next message carries handles. */
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
/* kind 0: a handle of your own table (it moves). kind 1/2/3: a BUFFER handle, sent by MOVE (the
 * receiver owns it; you do not), LEND (the receiver borrows it, you get it back when it returns it or
 * exits; you cannot use it meanwhile) or SHARE (a sealed buffer, read-only). At most 4 handles of any
 * kind per message. Buffer errors are -20 - BufError (-23 no such handle, -24 no right, -25 not the
 * owner, -29 transfer table full); the receiver reads a buffer's handle from info.got[i] with
 * info.kind[i] == 1 and uses it with nimixBufMap / nimixBufReturn / nimixBufClose. */
typedef struct { NimixHandle handle; unsigned rights; unsigned kind; } NimixSendEnt;
typedef struct { unsigned n; NimixSendEnt ent[4]; } NimixSendList;
typedef struct { int n; unsigned nGot; unsigned long long badge; NimixHandle got[4]; unsigned kind[4]; } NimixChanInfo;

int nimixChanPair(NimixChanPair* req);
int nimixChanWrite(NimixHandle h, const void* data, int len, const NimixSendList* send);
int nimixChanRead(NimixHandle h, void* buf, int cap, NimixChanInfo* info);
int nimixHandleClose(NimixHandle h);
int nimixHandleDup(NimixHandle h, unsigned rights);    /* the new handle, or < 0 */
int nimixChanStatus(NimixHandle h);                    /* bit 0 readable, bit 1 peer closed */

/* Block until one of up to 8 channel ends is readable or its peer has closed, or `ticks` (PIT
 * ticks, 10 ms; 0xFFFFFFFF = forever) pass. `ready` is set per item (bit 0 readable, bit 1 peer
 * closed). Returns how many items are ready, 0 on timeout, or < 0. A waiting task uses no CPU: a
 * channel write or close wakes it, and it runs at the next scheduling tick. */
typedef struct { NimixHandle handle; unsigned ready; } NimixWaitItem;
int nimixWait(NimixWaitItem* items, int n, unsigned ticks);

/* Batches: a stream crosses as one call per burst. Records are packed back to back, each a 16-bit
 * little-endian length then that many bytes (<= 256). A channel is the session ring: there is no
 * second queue type. A batch carries bytes only; a message with handles goes alone (nimixChanWrite).
 * nimixChanWriteBatch returns how many records were queued (fewer than `count` if the queue filled),
 * or < 0 (nothing queued). nimixChanReadBatch returns how many messages it unpacked (>= 1) or < 0;
 * -14 means the next message carries handles (use nimixChanRead), -8 that it does not fit (info.used
 * = bytes needed). It stops before a message with handles. Up to 16 records per batch. */
typedef struct { unsigned used, nMsgs; unsigned long long badge; } NimixBatchInfo;
int nimixChanWriteBatch(NimixHandle h, const void* records, int len, int count);
int nimixChanReadBatch(NimixHandle h, void* records, int cap, NimixBatchInfo* info);

/* How many syscalls this task has made so far, including this one: the number the cost model
 * ("about one kernel call per frame") is stated in. */
int nimixKernelCalls(void);

/* spawn: start the program at `path` (a PIE ELF on the disk) with exactly the handles listed in `req`.
 * `launcher` is a process handle with the spawn right; without one the call fails with -1. Each listed
 * handle is MOVED out of the caller's table (it must be transferable; `rights` may only narrow it) and
 * the i-th arrives in the child as NIMIX_BOOTSTRAP_HANDLE + i. The child has nothing else.
 * Returns the child's pid, or -1 bad handle/argument, -30 no such file, -31 not loadable, -32 out of
 * regions or tasks, -33 busy. */
/* Device ports (docs/proposals/device_ports.md). A port handle is given at spawn (manifest `grant input`);
 * it names ONE device module and cannot be duplicated. A message is the port wire form:
 *   byte 0 class (0 request, 1 reply, 2 event), 1 status, 2-3 op, 4-7 seq, 8-9 payload length, 10-11 zero,
 *   then the payload. Buffers passed to the two calls must hold a whole message (NIMIX_PORT_MSG bytes).
 * nimixPortCall sends the request in buf[0..len) and overwrites buf with the reply; it returns the reply
 * length, or -1 (bad handle or argument) or -(40 + status). nimixPortEvent returns the next event's
 * length, 0 if none is waiting, or < 0. nimixWait accepts a port handle: ready bit 0 = an event waits. */
#define NIMIX_PORT_MSG 256
#define NIMIX_PORT_DESCRIBE_OP 0xFFFEu     /* request every port answers: payload byte = port kind (0 = input) */
int nimixPortCall(NimixHandle h, void* buf, int len, int cap);
int nimixPortEvent(NimixHandle h, void* buf, int cap);

#define NIMIX_SPAWN_MAX 8
typedef struct { unsigned n; unsigned handle[NIMIX_SPAWN_MAX]; unsigned rights[NIMIX_SPAWN_MAX]; } NimixSpawnReq;
int nimixSpawn(NimixHandle launcher, const char* path, const char* args, const NimixSpawnReq* req);
