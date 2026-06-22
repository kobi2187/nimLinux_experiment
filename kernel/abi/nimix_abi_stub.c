/* NimixOS ABI weak stubs — linked into PIE app binaries.
 * The kernel loader overwrites these with `movabs rax, <fn>; jmp rax`
 * before calling appMain(), so the real kernel implementations run.
 * Weak linkage ensures user code overrides these if it provides its own.
 */
__attribute__((weak)) void nimixWrite(const void* buf, int len) { (void)buf; (void)len; }
__attribute__((weak)) void nimixExit(int code) { (void)code; while(1); }
__attribute__((weak)) void* nimixAllocRegion(int size) { (void)size; return (void*)0; }
__attribute__((weak)) void nimixFreeRegion(void* p, int size) { (void)p; (void)size; }
