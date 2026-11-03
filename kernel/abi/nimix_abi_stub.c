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

/* Each stub is overwritten in place by a 16-byte syscall trampoline, so every
 * stub must be at least 16 bytes long; STUB_PAD pads the tiny ones. The loader
 * refuses (and logs) any stub smaller than that rather than overrun it. */
#define STUB_PAD __asm__ volatile(".fill 16, 1, 0x90")

/*
 * The kernel loader overwrites these with `movabs rax, <fn>; jmp rax`
 * before calling appMain(), so the real kernel implementations run.
 */
__attribute__((weak)) void  nimixWrite(const void* buf, int len)            { (void)buf; (void)len; }
__attribute__((weak)) void  nimixExit(int code)                             { STUB_PAD; (void)code; while(1); }
__attribute__((weak)) void* nimixAllocRegion(int size)                      { (void)size; return (void*)0; }
__attribute__((weak)) void  nimixFreeRegion(void* p, int size)              { (void)p; (void)size; }
__attribute__((weak)) int   nimixChanSend(const char* name, const void* data, int len) { (void)name; (void)data; (void)len; return -1; }
__attribute__((weak)) int   nimixChanRecv(const char* name, void* buf, int len)        { (void)name; (void)buf; (void)len; return -1; }
__attribute__((weak)) void  nimixEventPublish(const char* topic, const void* data, int len) { (void)topic; (void)data; (void)len; }
__attribute__((weak)) unsigned int nimixEventSubscribe(const char* topic)   { (void)topic; return 0; }
__attribute__((weak)) int   nimixEventPoll(unsigned int token, void* buf, int len) { (void)token; (void)buf; (void)len; return -1; }
__attribute__((weak)) int  nimixGetArgs(void* buf, int len)                        { (void)buf; (void)len; return -1; }
__attribute__((weak)) int  nimixProcList(void* buf, int len)                       { (void)buf; (void)len; return -1; }
__attribute__((weak)) int  nimixSchedStats(void* buf, int len)                     { (void)buf; (void)len; return -1; }
__attribute__((weak)) int  nimixProcKillPid(unsigned int pid)                      { (void)pid; return -1; }
__attribute__((weak)) int  nimixFsReadDir(const char* path, void* buf, int len)    { (void)path; (void)buf; (void)len; return -1; }
__attribute__((weak)) int  nimixCapSend(const char* name, unsigned long long tok, const void* data, int len) { (void)name; (void)tok; (void)data; (void)len; return -1; }
__attribute__((weak)) int nimixChanCall(const char* server, const void* data, int dataLen, void* replyBuf, int replyBufLen) { (void)server; (void)data; (void)dataLen; (void)replyBuf; (void)replyBufLen; return -1; }
__attribute__((weak)) void nimixSleep(unsigned long long ticks) { STUB_PAD; (void)ticks; }
__attribute__((weak)) void nimixYield(void) { STUB_PAD;}
__attribute__((weak)) int  nimixSysInfo(void* buf, int len) { (void)buf; (void)len; return -1; }
__attribute__((weak)) unsigned long long nimixGrantRegion(int slot, unsigned int right) { (void)slot; (void)right; return 0; }
__attribute__((weak)) int nimixFsRead(const char* path, void* buf, int len) { (void)path; (void)buf; (void)len; return -1; }
__attribute__((weak)) int nimixFsWrite(const char* path, const void* buf, int len) { (void)path; (void)buf; (void)len; return -1; }
__attribute__((weak)) unsigned long long nimixUptimeSecs(void) { STUB_PAD; return 0; }
__attribute__((weak)) int nimixWallClock(void* buf, int len) { (void)buf; (void)len; return -1; }
__attribute__((weak)) void* nimixMapAnon(int size) { (void)size; return (void*)0; }
__attribute__((weak)) void  nimixFreeAnon(void* p, int size) { (void)p; (void)size; }
__attribute__((weak)) int  nimixSndPlay(const void* pcm, int len) { (void)pcm; (void)len; return -1; }
__attribute__((weak)) int  nimixSndDrain(void) { STUB_PAD; return -1; }
__attribute__((weak)) unsigned long long nimixChanCreate(const char* name) { (void)name; return 0; }
__attribute__((weak)) int  nimixCapRecv(unsigned long long tok, void* buf, int len) { (void)tok; (void)buf; (void)len; return -1; }
/* buffers (ipc/buffers): errors are -ord(BufError) */
__attribute__((weak)) int  nimixBufCreate(int size) { STUB_PAD; (void)size; return -1; }
__attribute__((weak)) void* nimixBufMap(unsigned int h) { STUB_PAD; (void)h; return (void*)0; }
__attribute__((weak)) int  nimixBufClose(unsigned int h) { STUB_PAD; (void)h; return -1; }
__attribute__((weak)) int  nimixBufSeal(unsigned int h) { STUB_PAD; (void)h; return -1; }
__attribute__((weak)) int  nimixBufReturn(unsigned int h) { STUB_PAD; (void)h; return -1; }
__attribute__((weak)) int  nimixBufMsgSend(const char* name, const void* data, int len, void* hs) { STUB_PAD; (void)name; (void)data; (void)len; (void)hs; return -1; }
__attribute__((weak)) int  nimixBufMsgRecv(unsigned long long tok, void* buf, int len, void* hs) { STUB_PAD; (void)tok; (void)buf; (void)len; (void)hs; return -1; }
