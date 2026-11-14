# SPDX-License-Identifier: GPL-2.0
## Pointer arguments of a ring-3 syscall, checked at the gate, before the kernel touches them.
##
## The kernel implementation of a syscall copies from / to the pointers it is given. A ring-3
## program controls them, so without a check it can make the kernel read or write any address:
## its own kernel image, another task's region, device memory. This module is the one place that
## says which syscall arguments are pointers and how big the memory behind each must be; the gate
## (arch/x86_64/syscall_gate.nim) refuses a call whose pointers leave the caller's own memory.
##
## "The caller's own memory" = its app region (code, data, heap, stack) and the arena blocks the
## buffers store currently lets it access (read for a buffer the kernel only reads, read-write for
## one it writes: a sealed or borrowed buffer is not writable). The arena rights come in through
## `ArenaAccess` (kernel/buffers/kbuffers.nim); without one (host tests) the arena is a plain range.
##
## Pure and host-tested (tests/test_user_args.nim), which also cross-checks this table against the
## ABI vtable: every syscall with a `pointer` or `cstring` parameter must have an entry here, so a
## new syscall cannot be added without saying how its pointers are checked.
import ../display/display_checks   # inRange

const
  MaxCStr* = 512                   ## a name or path longer than this (or unterminated) is refused
  BufMsgHandlesBytes* = 4 + 4 * 4 + 4 * 4   ## BufMsgHandles: n + 4 handles + 4 modes (kbuffers asserts it)

type
  ArenaAccess* = proc(p, n: uint64; write: bool): bool {.nimcall.}
    ## May the running task read (or write) arena bytes [p, p+n)?

  ArgKind* = enum
    akStr        ## NUL-terminated string at arg p, terminating within MaxCStr bytes inside user memory
    akBuf        ## buffer at arg p, of (arg n) * elem bytes; arg n < 0 is refused, 0 means no access
    akStruct     ## fixed-size struct at arg p (n = its size in bytes); `optional` allows nil
    akOpaque     ## a pointer used only as a value (never dereferenced): nothing to check

  ArgSpec* = object
    nr*: uint8
    kind*: ArgKind
    p*: uint8                      ## index of the pointer argument (0..3)
    n*: uint16                     ## akBuf: index of the length argument; akStruct: size in bytes
    elem*: uint8                   ## akBuf: bytes per unit of the length (1 for byte counts)
    optional*: bool
    wr*: bool                      ## the kernel WRITES through this pointer (else it only reads)

func s(nr: int): ArgSpec = ArgSpec(nr: uint8(nr), kind: akStr, p: 0)
func b(nr, p, n: int; elem = 1; wr = false): ArgSpec =
  ArgSpec(nr: uint8(nr), kind: akBuf, p: uint8(p), n: uint16(n), elem: uint8(elem), wr: wr)
func st(nr, p, size: int; optional = false; wr = false): ArgSpec =
  ArgSpec(nr: uint8(nr), kind: akStruct, p: uint8(p), n: uint16(size), optional: optional, wr: wr)
func o(nr, p: int): ArgSpec = ArgSpec(nr: uint8(nr), kind: akOpaque, p: uint8(p))

const ArgSpecs* = [
  b(0, 0, 1),                                  # write(buf, len)
  o(3, 0),                                     # freeRegion(p, size): p is a value
  s(4), b(4, 1, 2),                            # chanSend(name, data, len)
  s(5), b(5, 1, 2, wr = true),                        # chanRecv(name, buf, len)
  s(6), b(6, 1, 2),                            # eventPublish(topic, data, len)
  s(7),                                        # eventSubscribe(topic)
  b(8, 1, 2, wr = true),                                  # eventPoll(token, buf, len)
  b(9, 0, 1, wr = true),                                  # getArgs(buf, len)
  b(10, 0, 1, wr = true),                                 # procList(buf, len)
  b(11, 0, 1, wr = true),                                 # schedStats(buf, len)
  s(13), b(13, 1, 2, wr = true),                          # fsReadDir(path, buf, len)
  s(14), b(14, 1, 2, wr = true),                          # fsRead(path, buf, len)
  s(15), b(15, 1, 2),                          # fsWrite(path, buf, len)
  s(16), b(16, 2, 3),                          # capSend(name, tok, data, len)
  s(17), b(17, 1, 2), o(17, 3),                # chanCall(server, data, len, replyBuf, replyLen): the 5th
                                               #   argument cannot cross the 4-register gate, so replyLen is 0
  b(20, 0, 1, wr = true),                                 # sysInfo(buf, len)
  b(23, 0, 1, wr = true),                                 # wallClock(buf, len)
  o(25, 0),                                    # freeAnon(p, size): p is a value
  b(26, 0, 1),                                 # sndPlay(pcm, byteLen): the device DMAs from it
  s(28),                                       # chanCreate(name)
  b(29, 1, 2, wr = true),                                 # capRecv(tok, buf, len)
  s(35), b(35, 1, 2), st(35, 3, BufMsgHandlesBytes, optional = true),   # bufMsgSend(name, data, len, hs)
  b(36, 1, 2, wr = true), st(36, 3, BufMsgHandlesBytes, optional = true, wr = true),          # bufMsgRecv(tok, buf, len, hs)
  st(37, 0, 20, wr = true),                               # displayInfo(out): 5 x u32
  st(38, 0, 36),                               # displayPresent(req): 9 x u32
  b(39, 0, 1, elem = 8, wr = true),
  st(41, 0, 40, wr = true),                    # chanPair(req): rights and badges in, two handles out
  b(42, 1, 2), st(42, 3, 36, optional = true), # chanWrite(h, data, len, sendList): data read; list read
  b(43, 1, 2, wr = true), st(43, 3, 32, optional = true, wr = true),  # chanRead(h, buf, cap, info)
  b(47, 0, 1, elem = 8, wr = true)]            # wait(items, n, ticks): n x (handle, ready)                       # displayModes(out, max): max x (w, h)

func refusedResult*(nr: uint64): uint64 =
  ## What a refused call returns: -1, except where the syscall's failure value is 0 (those that
  ## return a token: eventSubscribe, chanCreate), so a caller testing `== 0` sees the failure.
  if nr == 7 or nr == 28: 0'u64 else: high(uint64)

func argAt(a: array[4, uint64]; i: uint8): uint64 = a[int(i) and 3]

proc inUser(p, n, rlo, rhi, alo, ahi: uint64; write: bool; aa: ArenaAccess): bool =
  ## [p, p+n) lies wholly in the caller's region, or wholly in the arena where the caller may
  ## access it (read, or write if the kernel writes).
  if inRange(p, n, rlo, rhi): return true
  if inRange(p, n, alo, ahi): return aa == nil or aa(p, n, write)
  false

proc cstrOk(p, rlo, rhi, alo, ahi: uint64; aa: ArenaAccess): bool =
  ## A NUL within MaxCStr bytes, all of it inside ONE user range: the one holding the first
  ## byte (a string may not run from the region into the arena that happens to follow it).
  ## Reads the string, so `p` must be a real address (the kernel runs in the caller's address space).
  if p == 0: return false
  var hi: uint64
  var inArena = false
  if inRange(p, 1, rlo, rhi): hi = rhi
  elif inRange(p, 1, alo, ahi): hi = ahi; inArena = true
  else: return false
  let limit = min(hi - p, uint64(MaxCStr))            # p < hi, so this is at least 1
  if inArena and aa != nil and not aa(p, limit, false): return false
  for i in 0'u64 ..< limit:
    if cast[ptr byte](p + i)[] == 0: return true
  false

proc userArgsOk*(nr: uint64; a: array[4, uint64]; rlo, rhi, alo, ahi: uint64;
                 aa: ArenaAccess = nil): bool =
  ## May the kernel run syscall `nr` with arguments `a`? False means a pointer leaves the
  ## caller's memory (region [rlo, rhi), arena [alo, ahi) as `aa` allows); the gate then returns
  ## -1 and runs nothing.
  for sp in ArgSpecs:
    if uint64(sp.nr) != nr: continue
    let p = argAt(a, sp.p)
    case sp.kind
    of akOpaque: discard
    of akStr:
      if not cstrOk(p, rlo, rhi, alo, ahi, aa): return false
    of akBuf:
      let n = cast[int64](argAt(a, uint8(sp.n)))
      if n < 0: return false
      if n == 0: continue
      let bytes = uint64(n)
      if bytes > (high(uint64) div uint64(sp.elem)): return false  # n * elem would wrap
      if not inUser(p, bytes * uint64(sp.elem), rlo, rhi, alo, ahi, sp.wr, aa): return false
    of akStruct:
      if p == 0 and sp.optional: continue
      if not inUser(p, uint64(sp.n), rlo, rhi, alo, ahi, sp.wr, aa): return false
  true
