# SPDX-License-Identifier: GPL-2.0
## FatFs write operations — create, write, delete, mkdir.
## Separate from fatfs.nim (read) to keep files focused.

import fatfs   # fsMounted, FR_OK, FRESULT, FIL, FA_WRITE, f_open, f_close, fsMount

type WriteResult* = enum
  wOk, wMountError, wOpenError, wWriteError, wPartialWrite, wDeleteError, wMkdirError

when not defined(noKernelHardware):
  # ── Additional FatFs C API ──────────────────────────────────────────────────

  proc f_write(fp: ptr FIL; buf: pointer; btw: uint32; bw: ptr uint32): FRESULT
    {.importc: "f_write", header: "ff.h".}

  proc f_unlink(path: cstring): FRESULT
    {.importc: "f_unlink", header: "ff.h".}

  proc f_mkdir(path: cstring): FRESULT
    {.importc: "f_mkdir", header: "ff.h".}

  proc f_rename(oldpath: cstring; newpath: cstring): FRESULT
    {.importc: "f_rename", header: "ff.h".}

  proc f_truncate(fp: ptr FIL): FRESULT
    {.importc: "f_truncate", header: "ff.h".}

  const
    FA_CREATE_ALWAYS = 0x08'u8   ## Create new file, overwrite if exists
    FA_CREATE_NEW    = 0x04'u8   ## Create new file, fail if exists
    FA_OPEN_APPEND   = 0x30'u8   ## Open file, append to end

proc fsWriteFile*(path: cstring; data: pointer; len: int): WriteResult =
  ## Write `len` bytes from `data` into `path`, creating or overwriting.
  when defined(noKernelHardware):
    if not fsMounted: return wMountError
    wOpenError   # no C layer; signal open failure
  else:
    if not fsMounted and not fsMount(): return wMountError
    var fp: FIL
    if f_open(addr fp, path, FA_WRITE or FA_CREATE_ALWAYS) != FR_OK:
      return wOpenError
    var written: uint32
    let r = f_write(addr fp, data, uint32(len), addr written)
    discard f_close(addr fp)
    if r != FR_OK: return wWriteError
    if int(written) != len: return wPartialWrite
    wOk

proc fsAppendFile*(path: cstring; data: pointer; len: int): WriteResult =
  ## Append `len` bytes to `path` (creates if not exists).
  when defined(noKernelHardware):
    if not fsMounted: return wMountError
    wOpenError
  else:
    if not fsMounted and not fsMount(): return wMountError
    var fp: FIL
    if f_open(addr fp, path, FA_WRITE or FA_OPEN_APPEND) != FR_OK:
      return wOpenError
    var written: uint32
    let r = f_write(addr fp, data, uint32(len), addr written)
    discard f_close(addr fp)
    if r != FR_OK: return wWriteError
    if int(written) != len: return wPartialWrite
    wOk

proc fsDeleteFile*(path: cstring): WriteResult =
  ## Delete the file at path.
  when defined(noKernelHardware):
    if not fsMounted: return wMountError
    wDeleteError
  else:
    if not fsMounted and not fsMount(): return wMountError
    if f_unlink(path) != FR_OK: return wDeleteError
    wOk

proc fsMkdir*(path: cstring): WriteResult =
  ## Create a directory at path.
  when defined(noKernelHardware):
    if not fsMounted: return wMountError
    wMkdirError
  else:
    if not fsMounted and not fsMount(): return wMountError
    if f_mkdir(path) != FR_OK: return wMkdirError
    wOk
