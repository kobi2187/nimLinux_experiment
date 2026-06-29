# SPDX-License-Identifier: GPL-2.0
## NimixOS ABI — filesystem procs.
## Provides: abiFsRead, abiFsReadDir, abiFsWrite.

when defined(kernelFull):
  import ../../fs/vfs

proc abiFsWrite*(path: cstring; buf: pointer; len: int): int {.nimcall.} =
  ## Write buf to file at path via vfs. Returns 0=ok, negative=error.
  when defined(kernelFull):
    let r = vfsWriteFile(path, buf, len)
    if r >= 0: 0 else: -1
  else:
    -1

proc abiFsReadDir*(path: cstring; buf: pointer; len: int): int {.nimcall.} =
  ## List directory at path into buf via vfs. Returns bytes written or negative on error.
  when defined(kernelFull):
    vfsDirList(path, buf, len)
  else:
    -1

proc abiFsRead*(path: cstring; buf: pointer; len: int): int {.nimcall.} =
  ## Read entire file into buf via vfs. Returns bytes read, or negative on error.
  when defined(kernelFull):
    let nbytes = vfsReadInto(path, cast[ptr byte](buf), len)
    nbytes
  else:
    -1
