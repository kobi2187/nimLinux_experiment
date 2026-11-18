/* NimixOS ABI weak stubs — linked into PIE app binaries.
 *
 * Also provides minimal libc builtins required by Nim's ARC allocator
 * when compiled with -ffreestanding (no libc available).
 */

typedef unsigned long size_t;
typedef unsigned long long uint64_t;

/* Page source for the app's Nim allocator (-d:nimAllocPagesViaMalloc). */
#define NIMIX_ARENA_BYTES (1UL * 1024 * 1024)
#include "nimix_page_arena.h"

/* Minimal FILE/stderr stub so Nim's raiseOutOfMem doesn't need libc */
typedef struct { int dummy; } FILE;
static FILE _stderr_stub = {0};
FILE* stderr = &_stderr_stub;
int fprintf(FILE* f, const char* fmt, ...) { (void)f; (void)fmt; return 0; }
size_t fwrite(const void* p, size_t s, size_t n, FILE* f) { (void)p;(void)s;(void)n;(void)f; return 0; }
int fflush(FILE* f) { (void)f; return 0; }
/* syncio error-path helpers — pulled in by --os:any apps (dispatch_server) */
int ferror(FILE* f) { (void)f; return 0; }
void clearerr(FILE* f) { (void)f; }
static int _errno_stub;
int* __errno_location(void) { return &_errno_stub; }
char* strerror(int e) { (void)e; return (char*)""; }
size_t strlen(const char* s) { size_t n=0; while(s[n]) n++; return n; }
void exit(int code) { (void)code; while(1); }

void* memset(void* s, int c, size_t n) {
  unsigned char* p = (unsigned char*)s;
  while (n--) *p++ = (unsigned char)c;
  return s;
}

void* memcpy(void* dst, const void* src, size_t n) {
  unsigned char* d = (unsigned char*)dst;
  const unsigned char* s = (const unsigned char*)src;
  while (n--) *d++ = *s++;
  return dst;
}

int memcmp(const void* a, const void* b, size_t n) {
  const unsigned char* p = (const unsigned char*)a;
  const unsigned char* q = (const unsigned char*)b;
  while (n--) { if (*p != *q) return (int)*p - (int)*q; p++; q++; }
  return 0;
}

void* memmove(void* dst, const void* src, size_t n) {
  unsigned char* d = (unsigned char*)dst;
  const unsigned char* s = (const unsigned char*)src;
  if (d < s) { while (n--) *d++ = *s++; }
  else { d += n; s += n; while (n--) *--d = *--s; }
  return dst;
}

/* The weak ABI stubs live in nimix_abi_weak.c (shared with C programs). */
#include "nimix_abi_weak.c"
