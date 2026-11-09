/* SPDX-License-Identifier: GPL-2.0
 * libctest — a plain C program on NimixOS: picolibc + libnimix, nothing else.
 * `libctest a b` runs every check and prints "libctest: ok" if all pass.
 * It is the V2b done-check: the libc surface raylib needs, exercised for real. */
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static int checks, fails;
static void check(int ok, const char *what) {
    checks++;
    if (!ok) { fails++; printf("libctest: FAIL %s\n", what); }
}

static int cmp_int(const void *a, const void *b) {
    int x = *(const int *)a, y = *(const int *)b;
    return (x > y) - (x < y);
}

static void test_stdio_and_parsing(void) {
    char buf[160];
    snprintf(buf, sizeof buf, "%d|%5.2f|%s|%x|%ld|%c|%08.3f", 42, 3.14159, "str", 255, 1234567890123L, 'Z', -2.5);
    check(strcmp(buf, "42| 3.14|str|ff|1234567890123|Z|-002.500") == 0, "snprintf formats");
    check(strtod("2.5e3", NULL) == 2500.0, "strtod");
    check(strtol("-0x1f", NULL, 0) == -31, "strtol");
    int a = 0; float b = 0; char w[16] = "";
    check(sscanf("12 3.5 abc", "%d %f %15s", &a, &b, w) == 3 && a == 12 && b == 3.5f && !strcmp(w, "abc"), "sscanf");
    check(toupper('q') == 'Q' && isdigit('7') && !isdigit('x'), "ctype");
    printf("libctest: stdout works (%s)\n", "printf");
    fprintf(stderr, "libctest: stderr works\n");
}

static void test_memory(void) {
    int v[200];
    unsigned s = 12345;
    for (int i = 0; i < 200; i++) { s = s * 1103515245u + 12345u; v[i] = (int)(s >> 8) % 1000; }
    qsort(v, 200, sizeof v[0], cmp_int);
    int sorted = 1;
    for (int i = 1; i < 200; i++) if (v[i - 1] > v[i]) sorted = 0;
    check(sorted, "qsort");

    void *p[300];
    int ok = 1;
    for (int i = 0; i < 300; i++) {                       /* many sizes, patterned, then verified */
        size_t n = 16 + (size_t)(i * 37) % 4000;
        p[i] = malloc(n);
        if (!p[i]) { ok = 0; break; }
        memset(p[i], i & 0xFF, n);
    }
    for (int i = 0; i < 300 && ok; i++) {
        size_t n = 16 + (size_t)(i * 37) % 4000;
        for (size_t j = 0; j < n; j += 97) if (((unsigned char *)p[i])[j] != (i & 0xFF)) ok = 0;
    }
    for (int i = 0; i < 300; i += 2) free(p[i]);
    char *big = malloc(4u << 20);                          /* 4 MB: more than an app slot, from the heap buffer */
    check(ok && big != NULL, "malloc many sizes + 4 MB");
    if (big) { memset(big, 0x5A, 4u << 20); check(big[(4u << 20) - 1] == 0x5A, "4 MB usable"); big = realloc(big, 8u << 20); check(big && big[12345] == 0x5A, "realloc keeps contents"); free(big); }
    for (int i = 1; i < 300; i += 2) free(p[i]);
    int *z = calloc(1000, sizeof *z);
    int zeros = z != NULL;
    for (int i = 0; z && i < 1000; i++) if (z[i]) zeros = 0;
    check(zeros, "calloc zeroes");
    free(z);
}

static void test_math(void) {
    check(fabsf(sinf(1.0f) - 0.84147098f) < 1e-6f, "sinf");
    check(powf(2.0f, 10.0f) == 1024.0f, "powf exact");
    check(sqrtf(2.0f) > 1.41421f && sqrtf(2.0f) < 1.41422f, "sqrtf");
    check(fabs(atan2(1.0, 1.0) * 4.0 - 3.14159265358979) < 1e-12, "atan2 double");
    check(fmodf(7.5f, 2.0f) == 1.5f && roundf(2.5f) == 3.0f, "fmodf, roundf");
}

static void test_time(void) {
    struct timespec t0, t1, d = { 0, 250 * 1000 * 1000 };
    check(clock_gettime(CLOCK_MONOTONIC, &t0) == 0, "clock_gettime");
    check(nanosleep(&d, NULL) == 0, "nanosleep");
    clock_gettime(CLOCK_MONOTONIC, &t1);
    long ms = (long)((t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_nsec - t0.tv_nsec) / 1000000);
    printf("libctest: slept 250 ms, measured %ld ms\n", ms);
    check(ms >= 250 && ms < 271, "nanosleep never early, at most one tick late (250..270 ms)");
    struct timeval tv;
    check(gettimeofday(&tv, NULL) == 0 && tv.tv_sec > 1700000000L, "gettimeofday is a real date");
    struct timespec bad = { 0, -1 };
    check(nanosleep(&bad, NULL) == -1 && errno == EINVAL, "nanosleep rejects a bad request");
}

static void test_files(void) {
    char buf[64];
    FILE *f = fopen("/LCTEST.TXT", "w");
    check(f != NULL, "fopen write");
    if (f) {
        fprintf(f, "hello %d from libctest\n", 2026);
        fputs("second line\n", f);
        check(fclose(f) == 0, "fclose writes the file back");
    }
    f = fopen("/LCTEST.TXT", "r");
    check(f != NULL, "fopen read it back");
    if (f) {
        check(fgets(buf, sizeof buf, f) && strcmp(buf, "hello 2026 from libctest\n") == 0, "fgets line 1");
        check(fgets(buf, sizeof buf, f) && strcmp(buf, "second line\n") == 0, "fgets line 2");
        check(fgets(buf, sizeof buf, f) == NULL && feof(f), "EOF after line 2");
        fseek(f, 6, SEEK_SET);
        check(fread(buf, 1, 4, f) == 4 && memcmp(buf, "2026", 4) == 0, "fseek + fread");
        fclose(f);
    }
    struct stat st;
    check(stat("/LCTEST.TXT", &st) == 0 && S_ISREG(st.st_mode) && st.st_size == 37, "stat size");
    check(stat("/", &st) == 0 && S_ISDIR(st.st_mode), "stat directory");
    check(stat("/NOPE.TXT", &st) == -1 && errno == ENOENT, "stat missing -> ENOENT");
    check(access("/LCTEST.TXT", F_OK) == 0 && access("/NOPE.TXT", F_OK) == -1, "access");

    f = fopen("/libctest.elf", "rb");                      /* a binary file that exists on the disk */
    check(f != NULL, "fopen an ELF");
    if (f) { unsigned char m[4] = { 0 }; check(fread(m, 1, 4, f) == 4 && m[0] == 0x7F && m[1] == 'E' && m[2] == 'L' && m[3] == 'F', "ELF magic"); fclose(f); }
    check(fopen("/NOPE.TXT", "r") == NULL && errno == ENOENT, "fopen missing -> ENOENT");
}

static void test_dirs(void) {
    DIR *d = opendir("/");
    check(d != NULL, "opendir /");
    int n = 0, found = 0;
    for (struct dirent *e; d && (e = readdir(d)) != NULL; n++) {
        char lower[64];
        size_t i = 0;
        for (; e->d_name[i] && i < sizeof lower - 1; i++) lower[i] = (char)tolower((unsigned char)e->d_name[i]);
        lower[i] = 0;
        if (!strcmp(lower, "libctest.elf")) found = 1;
    }
    if (d) closedir(d);
    printf("libctest: / has %d entries\n", n);
    check(n >= 3 && found, "readdir lists libctest.elf");
    char cwd[32];
    check(getcwd(cwd, sizeof cwd) && !strcmp(cwd, "/"), "getcwd");
    check(opendir("/NODIR") == NULL, "opendir missing");
}

static void test_refusals(void) {
    check(fork() == -1 && errno == ENOSYS, "fork refused");
    check(unlink("/LCTEST.TXT") == -1 && errno == ENOSYS, "unlink refused (no ABI call)");
}

/* The kernel must enter appMain like a called function (rsp = 8 mod 16): aligned
 * SSE stack stores (printf, memcpy, any double) fault otherwise. */
static void test_stack_alignment(void) {
    __attribute__((aligned(16))) volatile double slot = 1.0;
    check(((unsigned long)&slot & 15) == 0, "16-byte stack slots are 16-byte aligned");
}

int main(int argc, char **argv) {
    test_stack_alignment();
    printf("libctest: argc=%d", argc);
    for (int i = 1; i < argc; i++) printf(" [%s]", argv[i]);
    printf("\n");
    check(argc == 3 && !strcmp(argv[1], "a") && !strcmp(argv[2], "b"), "arguments reach main");
    test_stdio_and_parsing();
    test_memory();
    test_math();
    test_time();
    test_files();
    test_dirs();
    test_refusals();
    printf("libctest: %d checks, %d failed\n", checks, fails);
    if (!fails) printf("libctest: ok\n");
    return fails ? 1 : 0;
}
