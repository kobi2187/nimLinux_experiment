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
