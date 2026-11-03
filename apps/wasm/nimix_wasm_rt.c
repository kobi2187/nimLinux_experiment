/* SPDX-License-Identifier: GPL-2.0
 * nimix_wasm_rt.c — the libc corner Nim's runtime needs, inside a WASM app.
 * Linked into every Nim WASM app so the module imports ONLY NimixOS host
 * calls (env.serial_write, env.chan_send, ...), never libc.
 */
typedef unsigned long size_t;

__attribute__((import_module("env"), import_name("sip_exit")))
void sip_exit(int code);

/* Page source for Nim's allocator (-d:nimAllocPagesViaMalloc), page-aligned:
 * same contract as ELF apps (kernel/abi/nimix_page_arena.h). */
#define NIMIX_ARENA_BYTES (1UL * 1024 * 1024)   /* Nim's first request is ~516 KB */
#include "../../kernel/abi/nimix_page_arena.h"

void* memset(void* s, int c, size_t n) {
  unsigned char* p = s; while (n--) *p++ = (unsigned char)c; return s;
}
void* memcpy(void* d, const void* s, size_t n) {
  unsigned char* o = d; const unsigned char* i = s; while (n--) *o++ = *i++; return d;
}
void* memmove(void* d, const void* s, size_t n) {
  unsigned char* o = d; const unsigned char* i = s;
  if (o < i) { while (n--) *o++ = *i++; } else { o += n; i += n; while (n--) *--o = *--i; }
  return d;
}
int memcmp(const void* a, const void* b, size_t n) {
  const unsigned char *p = a, *q = b;
  for (; n--; p++, q++) if (*p != *q) return *p - *q;
  return 0;
}
size_t strlen(const char* s) { size_t n = 0; while (s[n]) n++; return n; }

/* Nim's fatal-error path writes to stderr; there is no console stream here. */
typedef struct { int unused; } FILE;
static FILE nimix_stderr;
FILE* stderr = &nimix_stderr;
size_t fwrite(const void* p, size_t s, size_t n, FILE* f) { (void)p; (void)f; return s * n; }
int fflush(FILE* f) { (void)f; return 0; }
void exit(int code) { sip_exit(code); __builtin_trap(); }
