# SPDX-License-Identifier: GPL-2.0
## Display ABI v1 (docs/proposals/display_abi.md): a ring-3 program presents a
## rectangle of a buffer it owns onto the virtio-gpu scanout.
##
## The kernel stays the only toucher of GPU memory. It reads the caller's
## buffer only through the buffers store (so a buffer moved or lent away cannot
## be shown), checks every rectangle (display_checks, host-tested), validates the
## request struct's own address, and copies bytes: the program does any pixel
## format conversion. Ownership is implicit: the first successful present owns
## the display until that task ends; the kernel console steps aside meanwhile.
import display_checks
import ../buffers/kbuffers
import ../console/fb_console
import ../process_table
import ../../drivers/virtio/virtio_gpu
import ../../mm/region_allocator
import ../../ipc/buffers/types
import ../../core/log

type
  NimixDisplayInfo {.packed.} = object
    size, width, height, format, strideBytes: uint32

  NimixPresent {.packed.} = object
    size, handle, strideBytes: uint32
    sx, sy, w, h, dx, dy: int32

const
  ErrBad  = -1        ## malformed request, unreadable buffer, or bad rectangle
  ErrBusy = -2        ## another task owns the display
  ErrNone = -3        ## no display device

var gOwnerPid: uint32      ## 0 = nobody (the kernel console owns the screen)

proc callerRegion(): tuple[lo, hi: uint64] =
  ## Where the caller's own memory may be: its app region and the buffer arena.
  ## (Buffer rights are enforced per page; regions are checked here.)
  let slot = procTable.tasks[procTable.current].regionSlot
  if slot < 0: return (0'u64, 0'u64)
  (RegionBase + uint64(slot) * RegionSize, RegionBase + uint64(slot + 1) * RegionSize)

proc userMemoryOk(p: pointer; n: int): bool =
  ## A request struct must lie in memory the caller owns, so the kernel can
  ## neither be made to write into itself nor to read another task's data.
  let a = cast[uint64](p)
  let r = callerRegion()
  inRange(a, uint64(n), r.lo, r.hi) or
    inRange(a, uint64(n), ArenaBase, ArenaBase + uint64(ArenaSize))

proc displaySize(w, h: var int): bool =
  w = int(virtioGpuWidth()); h = int(virtioGpuHeight())
  w > 0 and h > 0

proc abiDisplayInfo*(outp: pointer): int {.nimcall.} =
  var w, h: int
  if not displaySize(w, h): return ErrNone
  if outp == nil or not userMemoryOk(outp, sizeof(NimixDisplayInfo)): return ErrBad
  let o = cast[ptr NimixDisplayInfo](outp)
  o.size = uint32(sizeof(NimixDisplayInfo))
  o.width = uint32(w); o.height = uint32(h)
  o.format = DisplayFormatB8G8R8X8
  o.strideBytes = uint32(w * BytesPerPixel)
  0

proc abiDisplayPresent*(reqp: pointer): int {.nimcall.} =
  var dw, dh: int
  if not displaySize(dw, dh): return ErrNone
  if reqp == nil or not userMemoryOk(reqp, sizeof(NimixPresent)): return ErrBad
  let q = cast[ptr NimixPresent](reqp)[]           # one copy: no checking a value that can change
  if q.size < uint32(sizeof(NimixPresent)): return ErrBad
  let pid = procTable.tasks[procTable.current].pid
  if gOwnerPid != 0 and gOwnerPid != pid: return ErrBusy

  var base: uint64
  var size: int
  if not kbufReadable(q.handle, base, size): return ErrBad
  let r = PresentRect(stride: q.strideBytes, sx: q.sx, sy: q.sy, w: q.w, h: q.h, dx: q.dx, dy: q.dy)
  if checkPresent(r, int64(size), int64(dw), int64(dh)) != deOk: return ErrBad

  let fb = cast[ptr UncheckedArray[byte]](virtioGpuFbPtr())
  if fb == nil: return ErrNone
  if gOwnerPid == 0:                               # first present: take the screen
    gOwnerPid = pid
    fbConsoleSuspend(true)
    klogInt(llInfo, "display: owned by pid ", int64(pid))
  let src = cast[ptr UncheckedArray[byte]](base)
  let rowBytes = int(q.w) * BytesPerPixel
  let dstStride = dw * BytesPerPixel
  for row in 0 ..< int(q.h):
    copyMem(addr fb[(int(q.dy) + row) * dstStride + int(q.dx) * BytesPerPixel],
            addr src[(int(q.sy) + row) * int(q.strideBytes) + int(q.sx) * BytesPerPixel], rowBytes)
  virtioGpuPresentRect(int(q.dx), int(q.dy), int(q.w), int(q.h))
  0

proc displayRelease*(pid: uint32) =
  ## Task exit, kill or fault: hand the screen back to the console.
  if gOwnerPid != 0 and gOwnerPid == pid:
    gOwnerPid = 0
    fbConsoleSuspend(false)
    klogInt(llInfo, "display: released by pid ", int64(pid))
