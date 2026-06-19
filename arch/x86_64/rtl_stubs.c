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

/* Some architectures need this for division when hardware lacks it.
   Provide an empty stub since x86_64 has DIV instruction. */
long __udivmoddi4(unsigned long a, unsigned long b, unsigned long *mod) {
    (void)a;
    (void)b;
    (void)mod;
    return 0;
}
