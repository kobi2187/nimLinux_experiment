/* NimixOS ABI weak stubs — linked into PIE app binaries.
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
