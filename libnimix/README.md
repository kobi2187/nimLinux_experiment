# libnimix — the OS layer under picolibc

Any C program can run on NimixOS. [picolibc](../vendor/picolibc) supplies the
language library (`printf`, `strtod`, `qsort`, `malloc`, the whole of libm);
**libnimix** is the small layer that lets it run here by implementing the
handful of calls picolibc and raylib expect from an operating system. It is
about 500 lines, in four files, and a good map of where POSIX meets a
capability OS.

| file | what it gives a C program | how |
|------|--------------------------|-----|
| `crt.c` | `main`, `stdout`/`stderr`, `malloc`, `exit` | the loader calls `appMain` (found by name); stdio goes through `nimixWrite` with a line buffer; the heap (`sbrk`) is **one owned arena buffer** (memory is buffers); `_exit` flushes and calls `nimixExit` |
| `time.c` | `clock_gettime`, `gettimeofday`, `nanosleep` | monotonic time reads the kernel's **read-only time page** with the program's own `rdtsc`: no syscall; wall time is the RTC date plus the monotonic clock |
| `fs.c` | `open/read/write/lseek/close`, `fopen`, `stat`, `opendir`, `getcwd` | whole-file model over the VFS ABI: open reads the file into memory, close writes it back |
| `refused.c` | `fork`, `execve`, `fcntl`, `tcgetattr`, `mkdir`... | return -1 with an `errno`; each refusal has a stated reason |
| `nimix_timepage.h` | the clock reader | header-only; bit-identical to `core/tsc_clock.nim` (golden vectors) |

## Writing a C app

```c
#include <stdio.h>
int main(int argc, char **argv) { printf("hello %s\n", argc > 1 ? argv[1] : "world"); return 0; }
```

Put it in `apps/c/<name>/<name>.c`, add `<name>` to `C_APPS` in the Makefile,
`make build/apps/<name>.elf`; `make disk-add-apps` puts it on the disk, and the
shell runs it by name. `apps/c/libctest/libctest.c` is a worked example that
exercises everything above.

## Design points worth knowing

- **No ambient authority is implied, but the file ABI still has it.** The
  kernel's file calls take absolute paths (`nimixFsRead("/x")`), which is
  ambient authority: any program can name any file. That is an interim ABI;
  `fs_server` with lent buffers replaces it (BACKLOG B10) and the program-facing
  `open/read/write` shapes stay the same. The whole-file model here is what that
  future looks like to the program too.
- **The heap is budgeted.** The first `malloc` creates a 16 MB buffer from the
  task's buffer budget (32 MB). Build with `-DNIMIX_HEAP_BYTES=...` for more.
- **Sleeping is tick-quantised.** `nanosleep` never returns early, but can be up
  to one scheduler tick (10 ms) late: a precise wake needs a one-shot timer
  (LAPIC or TSC-deadline), not built yet.
- **Refusals are design, not gaps.** There is no `fork` because programs are
  started by the dispatcher with capabilities, not by cloning the caller.
- **Entry stack.** A function is entered with `rsp ≡ 8 (mod 16)`. The kernel
  used to enter `appMain` aligned, which Nim apps never noticed but any C
  program's `printf` (aligned SSE stores) did: a #GP. Fixed in
  `procSpawnRing3`; `libctest` checks it.

## Tests

- `make test-v2`: picolibc builds; raylib + rlsw + libnimix link with nothing
  unresolved; libm within 1 ULP; the C clock reader equals the Nim one.
- `make test-devices` (`libc`): `libctest a b` runs 42 checks on NimixOS under
  QEMU: formatting, parsing, `qsort`, 8 MB of `malloc`/`realloc`, libm, sleep,
  files, directories, refusals, argument passing.
