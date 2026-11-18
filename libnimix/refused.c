/* SPDX-License-Identifier: GPL-2.0
 * libnimix: the POSIX calls NimixOS refuses, each with the reason.
 *
 * These exist so C code links and fails cleanly at runtime (return -1 and set
 * errno) instead of failing to link. They are refusals by design, not gaps:
 *   - processes (fork/execve/waitpid): programs are started through the
 *     dispatcher with capabilities, not by cloning the caller;
 *   - terminals (tcgetattr/tcsetattr): there is no controlling terminal; input
 *     arrives as events;
 *   - fcntl: no descriptors are shared or inherited;
 *   - mkdir/rename/unlink/readlink: the interim file ABI (fs.c) has no such
 *     operations; fs_server will. */
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#define REFUSE(code) do { errno = (code); return -1; } while (0)

pid_t fork(void) { REFUSE(ENOSYS); }
int execve(const char *path, char *const argv[], char *const envp[]) {
    (void)path; (void)argv; (void)envp; REFUSE(ENOSYS);
}
pid_t waitpid(pid_t pid, int *status, int options) {
    (void)pid; (void)status; (void)options; REFUSE(ECHILD);
}
int fcntl(int fd, int cmd, ...) { (void)fd; (void)cmd; REFUSE(ENOSYS); }
int tcgetattr(int fd, struct termios *t) { (void)fd; (void)t; REFUSE(ENOTTY); }
int tcsetattr(int fd, int act, const struct termios *t) { (void)fd; (void)act; (void)t; REFUSE(ENOTTY); }
int mkdir(const char *path, mode_t mode) { (void)path; (void)mode; REFUSE(ENOSYS); }
int rename(const char *from, const char *to) { (void)from; (void)to; REFUSE(ENOSYS); }
int unlink(const char *path) { (void)path; REFUSE(ENOSYS); }
ssize_t readlink(const char *path, char *buf, size_t n) { (void)path; (void)buf; (void)n; REFUSE(EINVAL); }
