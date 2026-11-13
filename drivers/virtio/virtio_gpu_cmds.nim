# SPDX-License-Identifier: GPL-2.0
## Virtio-GPU command and response structures (virtio spec 5.7).
##
## All command/response messages begin with a 24-byte ctrl header.
## The 2D commands here drive a single dumb-framebuffer scanout.

const
  GpuCmdGetDisplayInfo*     = 0x0100'u32
  GpuCmdResourceCreate2d*   = 0x0101'u32
  GpuCmdResourceUnref*      = 0x0102'u32
  GpuCmdSetScanout*         = 0x0103'u32
  GpuCmdResourceFlush*      = 0x0104'u32
  GpuCmdTransferToHost2d*   = 0x0105'u32
  GpuCmdResourceAttachBacking* = 0x0106'u32

  GpuRespOkNodata*          = 0x1100'u32
  GpuRespOkDisplayInfo*     = 0x1101'u32

  GpuFormatB8G8R8X8Unorm*   = 2'u32

  GpuMaxScanouts* = 16

type
  GpuCtrlHdr* {.packed.} = object
    cmdType*:  uint32
    flags*:    uint32
    fenceId*:  uint64
    ctxId*:    uint32
    padding*:  uint32

  GpuRect* {.packed.} = object
    x*, y*, w*, h*: uint32

  GpuResourceCreate2d* {.packed.} = object
    hdr*:        GpuCtrlHdr
    resourceId*: uint32
    format*:     uint32
    width*:      uint32
    height*:     uint32

  GpuResourceUnref* {.packed.} = object
    hdr*:        GpuCtrlHdr
    resourceId*: uint32
    padding*:    uint32

  GpuSetScanout* {.packed.} = object
    hdr*:        GpuCtrlHdr
    r*:          GpuRect
    scanoutId*:  uint32
    resourceId*: uint32

  GpuMemEntry* {.packed.} = object
    addrLo*:  uint64
    length*:  uint32
    padding*: uint32

  GpuAttachBacking* {.packed.} = object
    hdr*:        GpuCtrlHdr
    resourceId*: uint32
    nrEntries*:  uint32
    entry*:      GpuMemEntry

  GpuTransferToHost2d* {.packed.} = object
    hdr*:        GpuCtrlHdr
    r*:          GpuRect
    offset*:     uint64
    resourceId*: uint32
    padding*:    uint32

  GpuResourceFlush* {.packed.} = object
    hdr*:        GpuCtrlHdr
    r*:          GpuRect
    resourceId*: uint32
    padding*:    uint32

  GpuDisplayOne* {.packed.} = object
    r*:        GpuRect
    enabled*:  uint32
    flags*:    uint32

  GpuDisplayInfo* {.packed.} = object
    hdr*:      GpuCtrlHdr
    pmodes*:   array[GpuMaxScanouts, GpuDisplayOne]

proc mkHdr*(cmdType: uint32): GpuCtrlHdr {.inline.} =
  result.cmdType = cmdType

proc fullRect*(w, h: uint32): GpuRect {.inline.} =
  result.w = w
  result.h = h
