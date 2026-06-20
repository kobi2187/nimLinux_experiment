/* SPDX-License-Identifier: GPL-2.0
 * NimixOS - RTL Stubs for Freestanding x86_64
 *
 * Provides minimal implementations of libc functions
 * that the Nim runtime expects in freestanding mode.
 *
 * These are used by Nim's system.nim generated C code for:
 *   - Memory operations (memset, memcpy, memmove)
 *   - String operations (strlen)
 *   - Error handling fallbacks (exit, stderr)
 */

typedef __SIZE_TYPE__ size_t;

/* ── Memory operations ──────────────────────────────────────────── */

void *memset(void *s, int c, size_t n) {
    unsigned char *p = (unsigned char *)s;
    for (size_t i = 0; i < n; i++) {
        p[i] = (unsigned char)c;
    }
    return s;
}

void *memcpy(void *dest, const void *src, size_t n) {
    unsigned char *d = (unsigned char *)dest;
    const unsigned char *s = (const unsigned char *)src;
    for (size_t i = 0; i < n; i++) {
        d[i] = s[i];
    }
    return dest;
}

void *memmove(void *dest, const void *src, size_t n) {
    unsigned char *d = (unsigned char *)dest;
    const unsigned char *s = (const unsigned char *)src;
    if (d < s) {
        for (size_t i = 0; i < n; i++) {
            d[i] = s[i];
        }
    } else {
        for (size_t i = n; i > 0; i--) {
            d[i - 1] = s[i - 1];
        }
    }
    return dest;
}

int memcmp(const void *s1, const void *s2, size_t n) {
    const unsigned char *p1 = (const unsigned char *)s1;
    const unsigned char *p2 = (const unsigned char *)s2;
    for (size_t i = 0; i < n; i++) {
        if (p1[i] != p2[i]) {
            return (int)p1[i] - (int)p2[i];
        }
    }
    return 0;
}

/* ── String operations ──────────────────────────────────────────── */

size_t strlen(const char *s) {
    size_t len = 0;
    while (s[len] != '\0') {
        len++;
    }
    return len;
}

char *strcpy(char *dest, const char *src) {
    char *d = dest;
    while ((*d++ = *src++) != '\0') {}
    return dest;
}

/* ── Error handling (kernel halts instead of aborting) ──────────── */

/* Provide a dummy FILE type so stderr has a type. */
typedef struct { int _dummy; } FILE;

static FILE __stderr_storage;
FILE *stderr = &__stderr_storage;

size_t fwrite(const void *ptr, size_t size, size_t nmemb, FILE *stream) {
    (void)ptr;
    (void)size;
    (void)stream;
    /* Kernel: silently ignore stderr writes */
    return nmemb;
}

int fflush(FILE *stream) {
    (void)stream;
    return 0;
}

void exit(int status) {
    (void)status;
    /* Kernel cannot exit — halt the CPU forever */
    for (;;) {
        __asm__ volatile("hlt");
    }
}

/* ── Debug serial output ───────────────────────────────────────── */

/* Minimal serial output for early debugging — called directly from assembly */
void debug_serial_char(char c) {
    unsigned short port = 0x3F8;
    /* Wait for transmitter to be ready */
    unsigned char lsr;
    do {
        __asm__ volatile("inb %1, %0" : "=a"(lsr) : "Nd"(port + 5));
    } while (!(lsr & 0x20));
    __asm__ volatile("outb %0, %1" :: "a"((unsigned char)c), "Nd"(port));
    /* Handle \n → \r\n */
    if (c == '\n') {
        do {
            __asm__ volatile("inb %1, %0" : "=a"(lsr) : "Nd"(port + 5));
        } while (!(lsr & 0x20));
        __asm__ volatile("outb %0, %1" :: "a"((unsigned char)'\r'), "Nd"(port));
    }
}

void debug_serial_str(const char *s) {
    while (*s) {
        debug_serial_char(*s);
        s++;
    }
}

/* ── Integer support ────────────────────────────────────────────── */

long __udivmoddi4(unsigned long a, unsigned long b, unsigned long *mod) {
    (void)a; (void)b; (void)mod;
    return 0;
}

/* ── Heap stubs for wasm3 (delegates to Nim ARC heap) ─────────────
 * wasm3 uses malloc/free/realloc for its internal data structures.
 * We forward these to the kernel's standalone heap (set via
 * -d:StandaloneHeapSize). Nim ARC's alloc/dealloc are safe to call
 * from C code compiled into the same binary.                       */

/* Nim ARC standalone heap — these symbols are emitted by Nim's C backend */
extern void *  nimBorrowedAlloc   (size_t size);
extern void    nimBorrowedDealloc (void *p, size_t size);

/* Simple bump allocator backed by a static arena.
 * wasm3 allocates ~100-200 KB for a small module.
 * We give it a 512 KB static pool to work from.    */
static unsigned char wasm_heap[512 * 1024];
static size_t        wasm_heap_used = 0;

/* Block header: stores size so free/realloc can find it */
typedef struct { size_t sz; } Hdr;

void *malloc(size_t size) {
    size_t aligned = (size + 15) & ~(size_t)15;
    size_t need    = sizeof(Hdr) + aligned;
    if (wasm_heap_used + need > sizeof(wasm_heap)) return 0;
    Hdr *h = (Hdr *)(wasm_heap + wasm_heap_used);
    h->sz = size;
    wasm_heap_used += need;
    return (void *)(h + 1);
}

void free(void *p) {
    (void)p;  /* bump allocator: no individual frees — reset between WASM runs */
}

void *realloc(void *p, size_t size) {
    if (!p) return malloc(size);
    Hdr *h = ((Hdr *)p) - 1;
    void *n = malloc(size);
    if (n && h->sz) {
        size_t copy = h->sz < size ? h->sz : size;
        memcpy(n, p, copy);
    }
    return n;
}

void *calloc(size_t nmemb, size_t size) {
    size_t total = nmemb * size;
    void *p = malloc(total);
    if (p) memset(p, 0, total);
    return p;
}

void wasm_heap_reset(void) {
    wasm_heap_used = 0;
}

/* Fortified glibc wrappers — clang may emit these; redirect to plain versions */
void *__memset_chk(void *s, int c, size_t n, size_t sz) { (void)sz; return memset(s, c, n); }
void *__memcpy_chk(void *d, const void *s, size_t n, size_t sz) { (void)sz; return memcpy(d, s, n); }

char *strchr(const char *s, int c) {
    while (*s) { if (*s == (char)c) return (char *)s; s++; }
    return c == 0 ? (char *)s : (char *)0;
}

char *strncpy(char *dst, const char *src, size_t n) {
    size_t i;
    for (i = 0; i < n && src[i]; i++) dst[i] = src[i];
    for (; i < n; i++) dst[i] = '\0';
    return dst;
}

/* ── wasm3 stubs — symbols wasm3 needs, not provided by -nostdlib ── */

int strcmp(const char *a, const char *b) {
    while (*a && *a == *b) { a++; b++; }
    return (unsigned char)*a - (unsigned char)*b;
}

int strncmp(const char *a, const char *b, size_t n) {
    while (n-- && *a && *a == *b) { a++; b++; }
    return n == (size_t)-1 ? 0 : (unsigned char)*a - (unsigned char)*b;
}

/* strtoul/strtoull: wasm3 uses these to parse type signatures */
unsigned long strtoul(const char *s, char **end, int base) {
    unsigned long r = 0;
    while (*s == ' ') s++;
    if (base == 0) base = 10;
    while (*s) {
        int d;
        if (*s >= '0' && *s <= '9') d = *s - '0';
        else if (*s >= 'a' && *s <= 'f') d = *s - 'a' + 10;
        else if (*s >= 'A' && *s <= 'F') d = *s - 'A' + 10;
        else break;
        if (d >= base) break;
        r = r * (unsigned long)base + (unsigned long)d;
        s++;
    }
    if (end) *end = (char *)s;
    return r;
}

unsigned long long strtoull(const char *s, char **end, int base) {
    return (unsigned long long)strtoul(s, end, base);
}

/* abort: wasm3 calls this on fatal internal error — we halt */
void abort(void) {
    for (;;) __asm__ volatile("cli; hlt");
}

/* __popcountdi2: used by wasm3's compile phase for bitmask ops */
int __popcountdi2(unsigned long long x) {
    int c = 0;
    while (x) { c += x & 1; x >>= 1; }
    return c;
}

/* m3_PrintProfilerInfo: wasm3 profiler stub (disabled but symbol needed) */
void m3_PrintProfilerInfo(void) {}
