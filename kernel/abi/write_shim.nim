# SPDX-License-Identifier: GPL-2.0
# write(2) syscall shim — routes fd writes to fdWrite.
import fd_table

proc write*(fd: cint; buf: pointer; count: csize_t): int {.exportc, cdecl.} =
  fdWrite(int(fd), buf, int(count))
