/* NimixOS ABI weak stubs — linked into PIE app binaries.
 *
 * Also provides minimal libc builtins required by Nim's ARC allocator
 * when compiled with -ffreestanding (no libc available).
 */

typedef unsigned long size_t;
typedef unsigned long long uint64_t;

/* Minimal FILE/stderr stub so Nim's raiseOutOfMem doesn't need libc */
typedef struct { int dummy; } FILE;
static FILE _stderr_stub = {0};
FILE* stderr = &_stderr_stub;
int fprintf(FILE* f, const char* fmt, ...) { (void)f; (void)fmt; return 0; }
size_t fwrite(const void* p, size_t s, size_t n, FILE* f) { (void)p;(void)s;(void)n;(void)f; return 0; }
int fflush(FILE* f) { (void)f; return 0; }
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

void* memmove(void* dst, const void* src, size_t n) {
  unsigned char* d = (unsigned char*)dst;
  const unsigned char* s = (const unsigned char*)src;
  if (d < s) { while (n--) *d++ = *s++; }
  else { d += n; s += n; while (n--) *--d = *--s; }
  return dst;
}

/*
 * The kernel loader overwrites these with `movabs rax, <fn>; jmp rax`
 * before calling appMain(), so the real kernel implementations run.
 */
__attribute__((weak)) void  nimixWrite(const void* buf, int len)            { (void)buf; (void)len; }
__attribute__((weak)) void  nimixExit(int code)                             { (void)code; while(1); }
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
__attribute__((weak)) void nimixSleep(unsigned long long ticks) { (void)ticks; }
__attribute__((weak)) void nimixYield(void) {}
__attribute__((weak)) int  nimixSysInfo(void* buf, int len) { (void)buf; (void)len; return -1; }
__attribute__((weak)) unsigned long long nimixGrantRegion(int slot, unsigned int right) { (void)slot; (void)right; return 0; }
__attribute__((weak)) int nimixFsRead(const char* path, void* buf, int len) { (void)path; (void)buf; (void)len; return -1; }
