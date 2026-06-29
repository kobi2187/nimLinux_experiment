# SPDX-License-Identifier: GPL-2.0
## FatFs wrapper — mount FAT volumes and read files
##
## Thin Nim binding over ChaN's FatFs (R0.16).
## Compiles ff.c and diskio.c alongside the kernel.
##
## Usage:
##   if fsMount():
##     let data = fsReadFile("ping.wasm")

const fatfsDir = "/home/kl/prog/nimLinux_experiment/vendor/fatfs"

{.passC: "-I" & fatfsDir.}

when not defined(noKernelHardware):
  {.passC: "-ffreestanding -fno-stack-protector -mno-red-zone -mcmodel=kernel -fno-pic".}
  {.compile: "/home/kl/prog/nimLinux_experiment/vendor/fatfs/ff.c".}
  {.compile: "/home/kl/prog/nimLinux_experiment/vendor/fatfs/ffunicode.c".}
  {.compile: "/home/kl/prog/nimLinux_experiment/vendor/fatfs/ffsystem.c".}
  {.compile: "/home/kl/prog/nimLinux_experiment/vendor/fatfs/diskio_virtio.c".}
  import ../drivers/virtio/diskio_virtio

import ../core/log
import vfs

# ── FatFs C types ─────────────────────────────────────────────────────────────

type
  FATFS   {.importc: "FATFS",   header: "ff.h".} = object
  FIL*    {.importc: "FIL",     header: "ff.h".} = object
  FFDIR   {.importc: "DIR",     header: "ff.h".} = object
  FILINFO {.importc: "FILINFO", header: "ff.h".} = object
    fsize   {.importc: "fsize".}:   uint32
    fattrib {.importc: "fattrib".}: uint8
    fname   {.importc: "fname".}:   array[256, char]

  FRESULT* = cint   ## FR_OK=0, errors > 0

const
  FR_OK*   = 0.FRESULT
  AM_DIR*  = 0x10'u8   ## fattrib bit: entry is a directory

# ── FatFs C API ───────────────────────────────────────────────────────────────

{.passC: "-I/home/kl/prog/nimLinux_experiment/vendor/fatfs".}

proc f_mount(fs: ptr FATFS; path: cstring; opt: uint8): FRESULT
  {.importc: "f_mount", header: "ff.h".}

proc f_open*(fp: ptr FIL; path: cstring; mode: uint8): FRESULT
  {.importc: "f_open", header: "ff.h".}

proc f_read(fp: ptr FIL; buf: pointer; btr: uint32; br: ptr uint32): FRESULT
  {.importc: "f_read", header: "ff.h".}

proc f_close*(fp: ptr FIL): FRESULT
  {.importc: "f_close", header: "ff.h".}

proc f_size(fp: ptr FIL): uint32
  {.importc: "f_size", header: "ff.h".}

proc f_stat(path: cstring; fno: ptr FILINFO): FRESULT
  {.importc: "f_stat", header: "ff.h".}

proc f_opendir(dp: ptr FFDIR; path: cstring): FRESULT
  {.importc: "f_opendir", header: "ff.h".}

proc f_readdir(dp: ptr FFDIR; fno: ptr FILINFO): FRESULT
  {.importc: "f_readdir", header: "ff.h".}

proc f_closedir(dp: ptr FFDIR): FRESULT
  {.importc: "f_closedir", header: "ff.h".}

const
  FA_READ*         = 0x01'u8
  FA_WRITE*        = 0x02'u8
  FA_OPEN_EXISTING = 0x00'u8

# ── Global filesystem state ───────────────────────────────────────────────────

var fatfsObj: FATFS
var fsMounted* = false

proc fsMount*(): bool =
  ## Mount the FAT volume on drive 0 (ATA primary master).
  let r = f_mount(addr fatfsObj, "", 1)  # "" = default drive, 1 = mount now
  if r == FR_OK:
    fsMounted = true
    klog(llInfo, "fs: FAT volume mounted")
    return true
  klogInt(llWarn, "fs: mount failed, err=", int64(r))
  false

# ── File reading ──────────────────────────────────────────────────────────────

type
  FileResult* = enum
    fOk
    fNotFound
    fReadError
    fTooBig
    fNotMounted

const MaxFileSize* = 512 * 1024  ## 512 KB max file read into kernel memory

proc fsFileSize*(path: cstring): int =
  ## Return file size in bytes, or -1 if not found.
  var info: FILINFO
  if f_stat(path, addr info) != FR_OK: return -1
  int(info.fsize)

proc fsReadInto*(path: cstring, buf: ptr byte, bufLen: int): tuple[res: FileResult, bytesRead: int] =
  ## Read a file from FAT into a caller-supplied buffer.
  ## Returns (fOk, bytesRead) on success.
  if not fsMounted:
    return (fNotMounted, 0)

  var fp: FIL
  if f_open(addr fp, path, FA_READ or FA_OPEN_EXISTING) != FR_OK:
    return (fNotFound, 0)

  let size = f_size(addr fp)
  if int(size) > bufLen:
    discard f_close(addr fp)
    return (fTooBig, 0)

  var bytesRead: uint32
  let r = f_read(addr fp, buf, size, addr bytesRead)
  discard f_close(addr fp)

  if r != FR_OK:
    return (fReadError, 0)

  (fOk, int(bytesRead))

# ── Directory listing ─────────────────────────────────────────────────────────

proc appendStr(buf: ptr UncheckedArray[char]; pos, cap: int; s: cstring): int =
  ## Append cstring s to buf at pos; return new pos. Stops at cap.
  var i = 0; var p = pos
  while s[i] != '\0' and p < cap: buf[p] = s[i]; inc i; inc p
  p

proc appendEntry(buf: ptr UncheckedArray[char]; pos, cap: int;
                 info: FILINFO): int =
  ## Append one directory entry line: "[DIR] name\n" or "name\n".
  var p = pos
  if (info.fattrib and AM_DIR) != 0:
    p = appendStr(buf, p, cap, "[DIR] ")
  p = appendStr(buf, p, cap, cast[cstring](unsafeAddr info.fname[0]))
  if p < cap: buf[p] = '\n'; inc p
  p

proc fsDirList*(path: cstring; buf: pointer; bufLen: int): int =
  ## Fill buf with one "name\n" line per directory entry.
  ## Returns bytes written, or negative on error.
  if not fsMounted:
    when not defined(noKernelHardware):
      if not fsMount(): return -1
    else:
      return -1
  when defined(noKernelHardware):
    return -1   # no C layer in test mode
  else:
    var dir: FFDIR
    if f_opendir(addr dir, path) != FR_OK: return -2
    let b = cast[ptr UncheckedArray[char]](buf)
    var pos = 0
    var info: FILINFO
    while true:
      if f_readdir(addr dir, addr info) != FR_OK: break
      if info.fname[0] == '\0': break
      pos = appendEntry(b, pos, bufLen, info)
    discard f_closedir(addr dir)
    pos
