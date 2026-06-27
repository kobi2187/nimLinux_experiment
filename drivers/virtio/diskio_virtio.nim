# SPDX-License-Identifier: GPL-2.0
## FatFs disk I/O bridge — exports C-callable symbols that diskio_virtio.c
## calls through. Replaces ATA PIO with virtio-blk sector I/O.
##
## Exported:
##   nimixBlkRead(sector, buf) → int   (0=ok, -1=error)
##   nimixBlkWrite(sector, buf) → int
##   nimixBlkReady() → int             (1=ready, 0=not ready)

import virtio_blk

proc nimixBlkReady(): cint {.exportc, cdecl.} =
  if gVirtioBlkReady: 1 else: 0

proc nimixBlkRead(sector: uint64; buf: pointer): cint {.exportc, cdecl.} =
  if virtioBlkRead(sector, buf): 0 else: -1

proc nimixBlkWrite(sector: uint64; buf: pointer): cint {.exportc, cdecl.} =
  if virtioBlkWrite(sector, buf): 0 else: -1
