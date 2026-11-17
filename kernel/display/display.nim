# SPDX-License-Identifier: GPL-2.0
## Display ABI v1 (docs/proposals/display_abi.md): a ring-3 program presents a
## rectangle of a buffer it owns onto the virtio-gpu scanout.
##
## The kernel stays the only toucher of GPU memory. It reads the caller's
## buffer only through the buffers store (so a buffer moved or lent away cannot
## be shown), checks every rectangle (display_checks, host-tested), validates the
## request struct's own address, and copies bytes: the program does any pixel
## format conversion. Access is by the display PORT (ipc/ports/display_port.nim): only the task holding
## its handle can draw (D3 option A); the first present by the holder takes the screen until that task ends
## or lets go, and the kernel console steps aside meanwhile.
import display_checks
import ../buffers/kbuffers
import ../console/fb_console
import ../console/console_input
import ../ports/kports
import ../process_table
import ../../drivers/virtio/virtio_gpu
import ../../ipc/ports/port
import ../../ipc/ports/display_port
import ../../core/log

static: doAssert MaxWireModes == MaxModes, "the display port's mode list is as long as the kernel's"
static: doAssert FormatBgrx == DisplayFormatB8G8R8X8

var gOwnerPid: uint32      ## 0 = nobody (the kernel console owns the screen)

proc displaySize(w, h: var int): bool =
  w = int(virtioGpuWidth()); h = int(virtioGpuHeight())
  w > 0 and h > 0

proc takeDisplay(pid: uint32) =
  ## The caller becomes the owner (no-op if it already is): the console steps aside.
  if gOwnerPid == 0:
    gOwnerPid = pid
    fbConsoleSuspend(true)
    consoleInputGrab(true)                          # input follows the display
    klogInt(llInfo, "display: owned by pid ", int64(pid))

proc bootMode(): DisplayMode =
  DisplayMode(w: virtioGpuBootWidth(), h: virtioGpuBootHeight())

proc displayHandler(ctx: pointer; req: PortMsg; rep: var PortMsg) {.nimcall.} =
  ## The display device module. It is reached only through the display port, whose single holder is the
  ## caller (the transport runs in the holder's own system call), so there is no ownership race to check:
  ## the handle IS the right to draw.
  var op: DisplayOp
  let s = displayOpOf(req, op)
  if s != psOk: rep.status = s; return
  var dw, dh: int
  if not displaySize(dw, dh): rep.status = psNoDevice; return
  let pid = procTable.tasks[procTable.current].pid
  case op                                           # exhaustive: a new DisplayOp will not compile until handled
  of doInfo:
    putPayload(rep, DisplayInfoWire(width: uint32(dw), height: uint32(dh), format: DisplayFormatB8G8R8X8,
                                    strideBytes: uint32(dw * BytesPerPixel)))
  of doModes:
    var ms: array[MaxModes, DisplayMode]
    let n = modeList(bootMode(), uint64(virtioGpuFbBytes()), ms)
    var w: DisplayModesWire
    w.count = uint8(min(n, MaxWireModes))
    for i in 0 ..< int(w.count): w.modes[i] = ModeWire(w: ms[i].w, h: ms[i].h)
    putPayload(rep, w)
  of doSetMode:
    var q: SetModeWire
    if not getPayload(req, q): rep.status = psBadArg; return
    if not modeAllowed(q.w, q.h, bootMode(), uint64(virtioGpuFbBytes())): rep.status = psBadArg; return
    takeDisplay(pid)
    if not virtioGpuSetMode(q.w, q.h): rep.status = psBadArg; return
    klogInt(llInfo, "display: mode ", int64(q.w))
  of doPresent:
    var q: PresentWire
    if not getPayload(req, q): rep.status = psBadArg; return   # one copy: no checking a value that can change
    var base: uint64
    var size: int
    if not kbufReadable(q.handle, base, size): rep.status = psBadArg; return   # only a buffer the caller owns and can read now
    let r = PresentRect(stride: q.strideBytes, sx: q.sx, sy: q.sy, w: q.w, h: q.h, dx: q.dx, dy: q.dy)
    if checkPresent(r, int64(size), int64(dw), int64(dh)) != deOk: rep.status = psBadArg; return
    let fb = cast[ptr UncheckedArray[byte]](virtioGpuFbPtr())
    if fb == nil: rep.status = psNoDevice; return
    takeDisplay(pid)                                # the first present by the holder takes the screen
    let src = cast[ptr UncheckedArray[byte]](base)
    let rowBytes = int(q.w) * BytesPerPixel
    let dstStride = dw * BytesPerPixel
    for row in 0 ..< int(q.h):
      copyMem(addr fb[(int(q.dy) + row) * dstStride + int(q.dx) * BytesPerPixel],
              addr src[(int(q.sy) + row) * int(q.strideBytes) + int(q.sx) * BytesPerPixel], rowBytes)
    virtioGpuPresentRect(int(q.dx), int(q.dy), int(q.w), int(q.h))

proc displayRelease*(pid: uint32) =
  ## Task exit, kill or fault: hand the screen back to the console.
  if gOwnerPid != 0 and gOwnerPid == pid:
    gOwnerPid = 0
    if virtioGpuWidth() != virtioGpuBootWidth() or virtioGpuHeight() != virtioGpuBootHeight():
      discard virtioGpuSetMode(virtioGpuBootWidth(), virtioGpuBootHeight())   # the console's mode
    consoleInputGrab(false)
    fbConsoleSuspend(false)
    klogInt(llInfo, "display: released by pid ", int64(pid))

proc displayReleaseHolder() {.nimcall.} =
  ## The display port's holder closed its handle or died: whoever owned the screen gives it back.
  if gOwnerPid != 0: displayRelease(gOwnerPid)

proc displayInit*() =
  ## Install the display device module behind the display port.
  kportInstallModule(pkDisplay, displayHandler, displayReleaseHolder)
