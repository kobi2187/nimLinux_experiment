/* SPDX-License-Identifier: GPL-2.0
 * nimix_page_arena.h — the page source behind Nim's allocator (kernel + apps).
 *
 * Built with -d:nimAllocPagesViaMalloc, Nim's allocator asks malloc() for page
 * memory and page-aligns it itself. Nim's own standalone heap
 * (-d:StandaloneHeapSize) is `array[..., float64]` — only 8-byte aligned — so
 * its chunk-header lookups (p & ~PageMask) read the wrong place: the first free
 * corrupted the heap in every binary (theHeap sat at page offset 0x60..0x6e0).
 *
 * Bump arena, like the standalone heap it replaces: free() releases nothing.
 * Apps only: the kernel keeps its own malloc (heap_manager, used by wasm3) and
 * page-aligns theHeap in kernel.ld instead. Define NIMIX_ARENA_BYTES first.
 */
#ifndef NIMIX_ARENA_BYTES
#error "define NIMIX_ARENA_BYTES before including nimix_page_arena.h"
#endif

static unsigned char nimix_arena[NIMIX_ARENA_BYTES] __attribute__((aligned(4096)));
static unsigned long nimix_arena_top;

void* malloc(unsigned long n) {
  n = (n + 15UL) & ~15UL;
  if (n > sizeof(nimix_arena) - nimix_arena_top) return (void*)0;
  void* p = nimix_arena + nimix_arena_top;
  nimix_arena_top += n;
  return p;
}

void free(void* p) { (void)p; }
