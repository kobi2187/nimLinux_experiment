# NimixOS buftest — exercises ipc/buffers enforcement from ring 3.
#   buftest ok     create, map, write, read back, seal, read again, close
#   buftest big    a server-sized heap: the whole default budget (32 MB) as ONE buffer,
#                  every page written and verified; the budget is real (a second
#                  allocation is refused) and comes back on close
#   buftest pass   move a buffer to our own channel and receive it back
#   buftest move   move a buffer away, then write through the old pointer  (#PF)
#   buftest seal   seal a buffer, then write to it                          (#PF)
#   buftest lend   lend a buffer away, then write to it while lent          (#PF)
# The faulting modes must be killed by the kernel; "still alive" never prints.
import nimix_common
import nimix_entry
import nimix_buffers

proc nimixChanCreate(name: cstring): uint64 {.importc, cdecl.}

const
  Size = 64 * 1024
  BigSize = 32 * 1024 * 1024     # DefaultBudget in kernel/buffers/kbuffers.nim
  Page = 4096

proc fail(msg: string) =
  write("buftest: FAIL " & msg & "\n"); nimixExit(1)

proc newMapped(): (uint32, ptr UncheckedArray[uint8]) =
  let h = nimixBufCreate(Size)
  if h <= 0: fail("create")
  let p = cast[ptr UncheckedArray[uint8]](nimixBufMap(uint32(h)))
  if p == nil: fail("map")
  for i in 0 ..< Size: p[i] = uint8(i and 0xFF)
  (uint32(h), p)

proc modeOk() =
  let (h, p) = newMapped()
  for i in 0 ..< Size:
    if p[i] != uint8(i and 0xFF): fail("readback")
  if nimixBufSeal(h) != 0: fail("seal")
  if nimixBufMap(h) == nil: fail("map sealed")
  if p[100] != 100'u8: fail("sealed read")
  if nimixBufClose(h) != 0: fail("close")
  write("buftest: ok\n")

proc modeBig() =
  ## V4: memory is buffers. A server's heap is one contiguous owned buffer from
  ## the arena: owned, budgeted and page-enforced like any bulk data.
  let h = nimixBufCreate(BigSize)
  if h <= 0: fail("create 32 MB")
  let p = cast[ptr UncheckedArray[uint8]](nimixBufMap(uint32(h)))
  if p == nil: fail("map 32 MB")
  var i = 0
  while i < BigSize:                      # a distinct byte per page, so a mis-mapped
    p[i] = uint8((i div Page) and 0xFF)   # page shows up as a wrong value
    i += Page
  p[BigSize - 1] = 0xA5'u8
  i = 0
  while i < BigSize:
    if p[i] != uint8((i div Page) and 0xFF): fail("readback page " & $(i div Page))
    i += Page
  if p[BigSize - 1] != 0xA5'u8: fail("last byte")
  if nimixBufCreate(Size) > 0: fail("budget not enforced: a second buffer was granted")
  if nimixBufClose(uint32(h)) != 0: fail("close")
  let again = nimixBufCreate(Size)        # the budget came back with the buffer
  if again <= 0: fail("budget not returned on close")
  discard nimixBufClose(uint32(again))
  write("buftest: big ok\n")

proc modePass() =
  let tok = nimixChanCreate("buftest")
  if tok == 0: fail("chanCreate")
  let (h, _) = newMapped()
  if sendOne("buftest", h, ModeMove, "pass") != 0: fail("send")
  var hs: BufMsgHandles
  var tag: array[16, char]
  if nimixBufMsgRecv(tok, addr tag[0], tag.len, addr hs) != 4 or hs.n != 1: fail("recv")
  let q = cast[ptr UncheckedArray[uint8]](nimixBufMap(hs.handle[0]))
  if q == nil or q[77] != 77'u8: fail("received contents")
  write("buftest: passed through a channel intact\n")

proc modeFault(mode: uint32) =
  discard nimixChanCreate("buftest")
  let (h, p) = newMapped()
  if mode == 99'u32:
    if nimixBufSeal(h) != 0: fail("seal")
    write("buftest: writing to a sealed buffer\n")
  else:
    if sendOne("buftest", h, mode, "away") != 0: fail("send")
    write("buftest: writing after giving the buffer away\n")
  p[0] = 1                         # must fault: this task has no write access now
  write("buftest: still alive?!\n")
  nimixExit(1)

proc appMain*() {.exportc.} =
  nimixAppInit()
  var a: array[16, char]
  let n = nimixGetArgs(addr a[0], a.len)
  var arg = ""
  for i in 0 ..< n:
    if a[i] == '\0': break
    arg.add a[i]
  if arg == "ok": modeOk()
  elif arg == "big": modeBig()
  elif arg == "pass": modePass()
  elif arg == "move": modeFault(ModeMove)
  elif arg == "lend": modeFault(ModeLend)
  elif arg == "seal": modeFault(99'u32)
  else: write("usage: buftest ok|big|pass|move|lend|seal\n")
  nimixExit(0)
