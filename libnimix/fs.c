/* SPDX-License-Identifier: GPL-2.0
 * libnimix part 3 of 3: files and directories, as POSIX shapes over the ABI.
 *
 * HONEST ABOUT THE SEAM. The ABI's file calls are whole-file and path-based
 * (nimixFsRead/Write/ReadDir through the in-kernel VFS): ambient authority,
 * which VISION axiom 6 says must not exist. fs_server with lent buffers will
 * replace them (BACKLOG B10, R-series). Until then libnimix gives programs the
 * POSIX shapes they expect (open/read/write/lseek/close, stat, opendir) with a
 * whole-file model: open reads the file into memory, writes accumulate in
 * memory, close writes the file back. That is also how the later fs_server
 * version will look to a program, so programs written against it keep working.
 *
 * Limits, by design: no append-in-place, no partial writes visible to others
 * before close, no file locking, no mkdir/rename/unlink/readlink (the ABI has
 * no such calls; see refused.c). fds 0 (stdin: EOF) 1 and 2 (the console). */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "nimix_abi.h"
#include "nimix_internal.h"

#define MAX_FILES   32
#define FIRST_FD    3
#define MAX_FILE    (64u * 1024 * 1024)      /* one whole file in memory: bound it */
#define PATH_MAX_   256

typedef struct {
    char    *path;
    uint8_t *data;
    size_t   size, cap, pos;
    int      writable, dirty;
    int      in_use;
} NFile;

static NFile files[MAX_FILES];
static char  cwd[PATH_MAX_] = "/";

/* "name" -> "/cwd/name"; absolute paths unchanged. */
static int resolve(const char *path, char *out) {
    if (!path || !*path) { errno = ENOENT; return -1; }
    size_t pl = strlen(path), cl = strlen(cwd);
    if (path[0] == '/') {
        if (pl >= PATH_MAX_) { errno = ENAMETOOLONG; return -1; }
        memcpy(out, path, pl + 1);
    } else {
        if (cl + pl + 2 > PATH_MAX_) { errno = ENAMETOOLONG; return -1; }
        memcpy(out, cwd, cl);
        if (cl > 1) out[cl++] = '/';
        memcpy(out + cl, path, pl + 1);
    }
    return 0;
}

/* Read a whole file. nimixFsRead is all-or-nothing: the whole file, or -2 when
 * the buffer is too small (retry with twice the room), or -1 (no such file). */
static int slurp(const char *path, uint8_t **data, size_t *size) {
    size_t cap = 4096;
    uint8_t *buf = malloc(cap);
    if (!buf) { errno = ENOMEM; return -1; }
    for (;;) {
        int n = nimixFsRead(path, buf, (int)cap);
        if (n >= 0) { *data = buf; *size = (size_t)n; return 0; }
        if (n != -2) { free(buf); errno = ENOENT; return -1; }
        if (cap >= MAX_FILE) { free(buf); errno = EFBIG; return -1; }
        cap *= 2;
        uint8_t *bigger = realloc(buf, cap);
        if (!bigger) { free(buf); errno = ENOMEM; return -1; }
        buf = bigger;
    }
}

static NFile *file_of(int fd) {
    if (fd < FIRST_FD || fd >= FIRST_FD + MAX_FILES || !files[fd - FIRST_FD].in_use) {
        errno = EBADF;
        return NULL;
    }
    return &files[fd - FIRST_FD];
}

int open(const char *path, int flags, ...) {
    char full[PATH_MAX_];
    if (resolve(path, full) != 0) return -1;
    int acc = flags & O_ACCMODE;
    int writable = acc == O_WRONLY || acc == O_RDWR;
    int i = 0;
    while (i < MAX_FILES && files[i].in_use) i++;
    if (i == MAX_FILES) { errno = EMFILE; return -1; }
    NFile *f = &files[i];
    memset(f, 0, sizeof *f);
    if ((flags & O_TRUNC) && writable) {
        f->data = malloc(1);                    /* start empty; creating happens on close */
        if (!f->data) { errno = ENOMEM; return -1; }
        f->dirty = 1;                           /* truncating is a write even if nothing follows */
    } else if (slurp(full, &f->data, &f->size) != 0) {
        if (!(writable && (flags & O_CREAT)) || errno != ENOENT) return -1;
        f->data = malloc(1);
        if (!f->data) { errno = ENOMEM; return -1; }
        f->dirty = 1;                           /* a created file exists after close */
    }
    f->cap = f->size;
    f->path = strdup(full);
    if (!f->path) { free(f->data); errno = ENOMEM; return -1; }
    f->writable = writable;
    f->pos = (flags & O_APPEND) ? f->size : 0;
    f->in_use = 1;
    return FIRST_FD + i;
}

ssize_t read(int fd, void *buf, size_t n) {
    if (fd == 0) return 0;                      /* stdin: EOF */
    NFile *f = file_of(fd);
    if (!f) return -1;
    if (f->pos >= f->size) return 0;
    if (n > f->size - f->pos) n = f->size - f->pos;
    memcpy(buf, f->data + f->pos, n);
    f->pos += n;
    return (ssize_t)n;
}

ssize_t write(int fd, const void *buf, size_t n) {
    if (fd == 1 || fd == 2) {                   /* the console: keep order with buffered stdio */
        nimix_console_flush();
        nimixWrite(buf, (int)n);
        return (ssize_t)n;
    }
    NFile *f = file_of(fd);
    if (!f) return -1;
    if (!f->writable) { errno = EBADF; return -1; }
    if (f->pos + n > MAX_FILE) { errno = EFBIG; return -1; }
    if (f->pos + n > f->cap) {
        size_t cap = f->cap ? f->cap : 64;
        while (cap < f->pos + n) cap *= 2;
        uint8_t *bigger = realloc(f->data, cap);
        if (!bigger) { errno = ENOMEM; return -1; }
        f->data = bigger;
        f->cap = cap;
    }
    if (f->pos > f->size) memset(f->data + f->size, 0, f->pos - f->size);   /* seek past end: a hole of zeros */
    memcpy(f->data + f->pos, buf, n);
    f->pos += n;
    if (f->pos > f->size) f->size = f->pos;
    f->dirty = 1;
    return (ssize_t)n;
}

off_t lseek(int fd, off_t off, int whence) {
    NFile *f = file_of(fd);
    if (!f) return -1;
    int64_t base = whence == SEEK_SET ? 0 : whence == SEEK_CUR ? (int64_t)f->pos
                 : whence == SEEK_END ? (int64_t)f->size : -1;
    if (base < 0 || base + off < 0) { errno = EINVAL; return -1; }
    f->pos = (size_t)(base + off);
    return (off_t)f->pos;
}

int close(int fd) {
    NFile *f = file_of(fd);
    if (!f) return -1;
    int rc = 0;
    if (f->dirty && nimixFsWrite(f->path, f->data, (int)f->size) < 0) { errno = EIO; rc = -1; }
    free(f->data);
    free(f->path);
    memset(f, 0, sizeof *f);
    return rc;
}

/* ── stat, access, cwd ───────────────────────────────────────────────────── */

static int is_dir(const char *full) {
    char probe[8];
    return nimixFsReadDir(full, probe, sizeof probe) >= 0;
}

int stat(const char *path, struct stat *st) {
    char full[PATH_MAX_];
    if (resolve(path, full) != 0) return -1;
    memset(st, 0, sizeof *st);
    st->st_nlink = 1;
    if (is_dir(full)) { st->st_mode = S_IFDIR | 0755; return 0; }
    uint8_t *data; size_t size;
    if (slurp(full, &data, &size) != 0) return -1;
    free(data);
    st->st_mode = S_IFREG | 0644;
    st->st_size = (off_t)size;
    st->st_blksize = 512;
    st->st_blocks = (blkcnt_t)((size + 511) / 512);
    return 0;
}

int access(const char *path, int mode) {
    (void)mode;                                 /* no permissions: exists or not */
    struct stat st;
    return stat(path, &st);
}

char *getcwd(char *buf, size_t size) {
    size_t n = strlen(cwd) + 1;
    if (!buf || size < n) { errno = ERANGE; return NULL; }
    memcpy(buf, cwd, n);
    return buf;
}

int chdir(const char *path) {
    char full[PATH_MAX_];
    if (resolve(path, full) != 0) return -1;
    if (!is_dir(full)) { errno = ENOTDIR; return -1; }
    size_t n = strlen(full);
    while (n > 1 && full[n - 1] == '/') full[--n] = 0;
    memcpy(cwd, full, n + 1);
    return 0;
}

/* ── directories ─────────────────────────────────────────────────────────────
 * The ABI lists a directory as text, "name\n" or "[DIR] name\n" per entry. */
typedef struct {
    DIR   base;            /* what <dirent.h> promises the caller */
    char *text;
    size_t len, pos;
} NDir;

DIR *opendir(const char *path) {
    char full[PATH_MAX_];
    if (resolve(path, full) != 0) return NULL;
    size_t cap = 4096;
    char *buf = malloc(cap);
    if (!buf) { errno = ENOMEM; return NULL; }
    int n;
    while ((n = nimixFsReadDir(full, buf, (int)cap)) >= (int)cap - 1) {
        cap *= 2;
        char *bigger = realloc(buf, cap);
        if (!bigger) { free(buf); errno = ENOMEM; return NULL; }
        buf = bigger;
    }
    if (n < 0) { free(buf); errno = ENOENT; return NULL; }
    NDir *d = calloc(1, sizeof *d);
    if (!d) { free(buf); errno = ENOMEM; return NULL; }
    d->text = buf;
    d->len = (size_t)n;
    return &d->base;
}

struct dirent *readdir(DIR *dir) {
    NDir *d = (NDir *)dir;
    if (d->pos >= d->len) return NULL;
    const char *line = d->text + d->pos;
    size_t ll = 0;
    while (d->pos + ll < d->len && line[ll] != '\n') ll++;
    d->pos += ll + 1;
    unsigned char type = DT_REG;
    if (ll >= 6 && memcmp(line, "[DIR] ", 6) == 0) { type = DT_DIR; line += 6; ll -= 6; }
    if (ll > sizeof d->base.dirent.d_name - 1) ll = sizeof d->base.dirent.d_name - 1;
    memcpy(d->base.dirent.d_name, line, ll);
    d->base.dirent.d_name[ll] = 0;
    d->base.dirent.d_type = type;
    d->base.dirent.d_ino = 0;
    return &d->base.dirent;
}

int closedir(DIR *dir) {
    NDir *d = (NDir *)dir;
    free(d->text);
    free(d);
    return 0;
}
