# SPDX-License-Identifier: GPL-2.0
## Tests for the syscall pointer-argument check (kernel/abi/user_args.nim).
{.define: noKernelHardware.}
import std/[strutils]
import ../kernel/abi/user_args
import ../kernel/abi/nimix_abi as abimod
import ../arch/x86_64/syscall_gate

var region, arena: array[4096, byte]           # stand-ins for the caller's region and the buffer arena
var other: array[4096, byte]                   # memory that is neither

proc a(x0 = 0'u64; x1 = 0'u64; x2 = 0'u64; x3 = 0'u64): array[4, uint64] = [x0, x1, x2, x3]
proc ad(p: pointer): uint64 = cast[uint64](p)

let rlo = ad(addr region[0])
let rhi = rlo + 4096
let alo = ad(addr arena[0])
let ahi = alo + 4096

proc ok(nr: uint64; args: array[4, uint64]): bool = userArgsOk(nr, args, rlo, rhi, alo, ahi)

proc put(buf: var array[4096, byte]; off: int; s: string) =
  for i, c in s: buf[off + i] = byte(c)
  buf[off + s.len] = 0

proc testBuffers() =
  # write(buf, len) = syscall 0
  assert ok(0, a(rlo, 100)), "inside the region"
  assert ok(0, a(alo + 8, 100)), "inside the arena"
  assert ok(0, a(rlo + 4096 - 16, 16)), "up to the last byte"
  assert not ok(0, a(rlo + 4096 - 16, 17)), "one byte past the end"
  assert not ok(0, a(rlo - 1, 8)), "starts before the region"
  assert not ok(0, a(ad(addr other[0]), 8)), "somewhere else"
  assert not ok(0, a(0x1000, 8)), "kernel low memory"
  assert not ok(0, a(rlo, 8192)), "longer than the region"
  assert not ok(0, a(rlo, cast[uint64](-1'i64))), "negative length"
  assert not ok(0, a(rlo, 0x8000_0000_0000_0000'u64)), "huge length"
  assert not ok(0, a(0xFFFF_FFFF_FFFF_FFF0'u64, 64)), "range wraps around the address space"
  assert ok(0, a(0x1000, 0)), "zero length touches nothing, whatever the pointer"
  # a region and an arena are separate ranges: a buffer may not straddle them
  assert not ok(0, a(rlo + 4090, 4096 + 100)), "no straddling"
  # displayModes(out, max): max x 8 bytes
  assert ok(39, a(rlo, 4)), "4 modes = 32 bytes"
  assert not ok(39, a(rlo, 1000)), "1000 modes = 8000 bytes: too big"
  assert not ok(39, a(rlo, 0x2000_0000_0000_0000'u64)), "max * 8 wraps"
  assert ok(39, a(0, 0)), "count only: max = 0, pointer ignored"
  echo "PASS: buffer arguments"

proc testStrings() =
  region.put(0, "mychan")
  assert ok(7, a(rlo)), "a short name"
  assert not ok(7, a(0)), "NULL name"
  assert not ok(7, a(0x2000)), "name in kernel memory"
  assert not ok(7, a(ad(addr other[0]))), "name elsewhere"
  for i in 0 ..< 600: region[100 + i] = byte('x')
  region[100 + 600] = 0
  assert not ok(7, a(rlo + 100)), "a name that does not end within MaxCStr"
  for i in 0 ..< 4096 - 10: region[10 + i] = byte('y')      # no NUL from byte 10 to the region's end
  assert not ok(7, a(rlo + 4096 - 4)), "unterminated and running off the region's end"
  region[4095] = 0
  assert ok(7, a(rlo + 4090)), "terminated in the last byte"
  # path + buffer together (fsRead = 14): both must pass
  region.put(0, "/FILE.TXT")
  assert ok(14, a(rlo, rlo + 64, 100))
  assert not ok(14, a(rlo, 0x1000, 100)), "good path, bad buffer"
  assert not ok(14, a(0x1000, rlo + 64, 100)), "bad path, good buffer"
  echo "PASS: string arguments"

proc testStructs() =
  # bufMsgRecv(tok, buf, len, hs) = 36: hs optional, BufMsgHandlesBytes long
  assert ok(36, a(1, rlo, 16, 0)), "no handles wanted"
  assert ok(36, a(1, rlo, 16, rlo + 100)), "handles struct inside"
  assert not ok(36, a(1, rlo, 16, rlo + 4096 - 8)), "handles struct runs off the end"
  assert not ok(36, a(1, rlo, 16, 0x1000)), "handles struct in kernel memory"
  # displayInfo(out) = 37 needs 20 bytes; displayPresent(req) = 38 needs 36; neither optional
  assert ok(37, a(rlo)) and not ok(37, a(0)) and not ok(37, a(rlo + 4096 - 19))
  assert ok(38, a(rlo)) and not ok(38, a(0)) and not ok(38, a(rlo + 4096 - 35))
  echo "PASS: struct arguments"

proc mockArena(p, n: uint64; write: bool): bool {.nimcall.} =
  ## the first 1 KB of the arena is readable by the caller, the first 512 bytes also writable
  let off = p - alo
  if write: off + n <= 512 else: off + n <= 1024

proc okA(nr: uint64; args: array[4, uint64]): bool = userArgsOk(nr, args, rlo, rhi, alo, ahi, mockArena)

proc testArenaRights() =
  # write(buf, len) reads: readable range is enough; chanRecv(name, buf, len) writes: needs write
  arena.put(0, "chan")
  assert okA(0, a(alo, 1024)), "read the readable part"
  assert not okA(0, a(alo, 1025)), "one byte past what the caller may read"
  assert not okA(0, a(alo + 2048, 16)), "an arena block the caller has no rights on"
  region.put(0, "chan")
  assert okA(5, a(rlo, alo, 512)), "chanRecv into a writable part"
  assert not okA(5, a(rlo, alo, 513)), "chanRecv into memory the caller may only read (a sealed buffer)"
  assert not okA(5, a(rlo, alo + 2048, 16)), "chanRecv into a block of another task"
  assert okA(7, a(alo)), "a name inside readable arena memory"
  assert not okA(7, a(alo + 2048)), "a name in an arena block the caller has no rights on"
  # a struct the kernel writes needs write; one it reads does not
  assert okA(37, a(alo)) and not okA(37, a(alo + 600)), "displayInfo out: writable only up to 512"
  assert okA(38, a(alo + 600)), "displayPresent req is only read"
  # the region is always the caller's own: the arena rights callback is not consulted for it
  assert okA(5, a(rlo, rlo + 100, 100))
  echo "PASS: arena rights (read vs write, per block)"

proc testOpaque() =
  assert ok(3, a(0xDEAD, 5)) and ok(25, a(0xDEAD, 5)), "freeRegion/freeAnon never dereference p"
  assert ok(1, a()) and ok(2, a(1 shl 30)) and ok(18, a(5)), "syscalls with no pointers always pass"
  echo "PASS: pointer-free syscalls and values"

proc ptrParamCount(typ: string; word: string): int =
  ## How many parameters of the proc type string have the given type (`pointer` or `cstring`).
  let params = typ.split("{.")[0]               # drop the pragma tail
  let head = params.split(")")[0]               # up to the closing paren of the parameter list
  for part in head.split({',', ';'}):
    if part.strip().endsWith(": " & word) or part.strip().endsWith(":" & word): inc result

proc testSpecCoversVtable() =
  ## Every syscall with a pointer or cstring parameter has a spec; every spec'd syscall has one.
  var v: NimixAbiVTable
  var checked = 0
  for sc in NimixSyscall:
    var fieldName = $NimixSyscallSymbol[sc]
    fieldName = fieldName[5 .. ^1]                # drop "nimix"
    fieldName[0] = toLowerAscii(fieldName[0])
    var found = false
    var specStr, specPtr = 0
    for sp in ArgSpecs:
      if int(sp.nr) == ord(sc):
        if sp.kind == akStr: inc specStr else: inc specPtr
    for name, fld in fieldPairs(v):
      if name == fieldName or name == fieldName & "*":
        found = true
        let t = $typeof(fld)
        let ptrs = ptrParamCount(t, "pointer")
        let strs = ptrParamCount(t, "cstring")
        assert specStr == strs, "syscall " & fieldName & ": " & $strs & " cstring params, " & $specStr & " string specs (" & t & ")"
        # a 5-argument syscall (chanCall) loses its last arg at the gate; its replyBuf spec is opaque
        assert specPtr == ptrs, "syscall " & fieldName & ": " & $ptrs & " pointer params, " & $specPtr & " pointer specs (" & t & ")"
        # a refused call must look like a failure to its caller: 0 for token-returning syscalls
        let retsToken = t.contains("): uint32") or t.contains("): uint64") or t.contains("): pointer")
        if specStr + specPtr > 0:
          assert (refusedResult(uint64(ord(sc))) == 0'u64) == retsToken, "syscall " & fieldName & ": refusal value does not match its return type (" & t & ")"
        inc checked
    assert found, "no vtable field for " & fieldName
  assert checked == NimixSyscallCount, $checked
  for sp in ArgSpecs: assert int(sp.nr) < NimixSyscallCount, "spec for a syscall that does not exist"
  echo "PASS: every pointer parameter of every syscall has a spec (", checked, " syscalls checked)"

when isMainModule:
  testBuffers()
  testStrings()
  testStructs()
  testArenaRights()
  testOpaque()
  testSpecCoversVtable()
  echo "All user_args tests passed."
