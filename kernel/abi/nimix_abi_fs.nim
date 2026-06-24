# SPDX-License-Identifier: GPL-2.0
## NimixOS ABI — filesystem procs.
## Provides: abiFsRead, abiFsReadDir, abiFsWrite.

when defined(kernelFull):
  import ../../fs/fatfs
  import ../../fs/fatfs_write

proc abiFsWrite*(path: cstring; buf: pointer; len: int): int {.nimcall.} =
  ## Write buf to file at path via fatfs. Returns 0=ok, negative=error.
  when defined(kernelFull):
    let r = fsWriteFile(path, buf, len)
    if r == wOk: 0 else: -1
  else:
    -1

proc abiFsReadDir*(path: cstring; buf: pointer; len: int): int {.nimcall.} =
  ## Directory listing — not yet implemented.
  -1

proc abiFsRead*(path: cstring; buf: pointer; len: int): int {.nimcall.} =
  ## Read entire file into buf via fatfs. Returns bytes read, or negative on error.
  when defined(kernelFull):
    if not fsMounted and not fsMount(): return -1
    let (res, nbytes) = fsReadInto(path, cast[ptr byte](buf), len)
    if res != fOk: return -2
    nbytes
  else:
    -1
