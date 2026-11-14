/* NimixOS ABI weak stubs — the syscall entry points, as patchable symbols.
 *
 * Linked into every ring-3 ELF (Nim apps via nimix_abi_stub.o, C apps via
 * nimix_abi_weak.o). The ELF loader finds each of these WEAK symbols in the
 * image's symbol table and overwrites it in place with a syscall trampoline.
 * Split from nimix_abi_stub.c so C programs, which have picolibc, don't also
 * get the mini-libc that file provides for Nim's standalone runtime.
 *
 * Build WITHOUT optimisation (the Makefile does): at -O0 even the empty stubs
 * are >= 16 bytes, which the 16-byte trampoline needs; STUB_PAD covers the rest. */
#include <stddef.h>

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
/* display (docs/proposals/display_abi.md): -1 bad request, -2 busy, -3 no display */
__attribute__((weak)) int  nimixDisplayInfo(void* out) { STUB_PAD; (void)out; return -3; }
__attribute__((weak)) int  nimixDisplayPresent(const void* req) { STUB_PAD; (void)req; return -3; }
__attribute__((weak)) int  nimixDisplayModes(void* out, int max) { STUB_PAD; (void)out; (void)max; return -3; }
__attribute__((weak)) int  nimixDisplaySetMode(unsigned w, unsigned h) { STUB_PAD; (void)w; (void)h; return -3; }
/* handles and channels */
__attribute__((weak)) int  nimixChanPair(void* req) { STUB_PAD; (void)req; return -1; }
__attribute__((weak)) int  nimixChanWrite(unsigned h, const void* data, int len, const void* send) { STUB_PAD; (void)h; (void)data; (void)len; (void)send; return -1; }
__attribute__((weak)) int  nimixChanRead(unsigned h, void* buf, int cap, void* info) { STUB_PAD; (void)h; (void)buf; (void)cap; (void)info; return -1; }
__attribute__((weak)) int  nimixHandleClose(unsigned h) { STUB_PAD; (void)h; return -1; }
__attribute__((weak)) int  nimixHandleDup(unsigned h, unsigned rights) { STUB_PAD; (void)h; (void)rights; return -1; }
__attribute__((weak)) int  nimixChanStatus(unsigned h) { STUB_PAD; (void)h; return -1; }
__attribute__((weak)) int  nimixWait(void* items, int n, unsigned ticks) { STUB_PAD; (void)items; (void)n; (void)ticks; return -1; }
