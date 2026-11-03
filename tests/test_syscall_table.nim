# SPDX-License-Identifier: GPL-2.0
## Tests for syscall dispatch table — host-side, no hardware required.
## Verifies enum ordinals, table size, and that all entries are filled
## after syscallTableInit().

{.define: noKernelHardware.}

import ../arch/x86_64/syscall_gate
import ../kernel/abi/nimix_abi as abimod
import ../runtime/elf_loader
import std/strutils

# Minimal stub vtable so syscallTableInit has something to read
proc stubWrite(buf: pointer; len: int) {.nimcall.} = discard
proc stubExit(code: int) {.nimcall.} = discard
proc stubAlloc(size: int): pointer {.nimcall.} = nil
proc stubFree(p: pointer; size: int) {.nimcall.} = discard
proc stubChanSend(name: cstring; data: pointer; len: int): int {.nimcall.} = 0
proc stubChanRecv(name: cstring; buf: pointer; len: int): int {.nimcall.} = 0
proc stubEventPublish(topic: cstring; data: pointer; len: int) {.nimcall.} = discard
proc stubEventSubscribe(topic: cstring): uint32 {.nimcall.} = 0
proc stubEventPoll(tok: uint32; buf: pointer; len: int): int {.nimcall.} = 0
proc stubGetArgs(buf: pointer; len: int): int {.nimcall.} = 0
proc stubProcList(buf: pointer; len: int): int {.nimcall.} = 0
proc stubSchedStats(buf: pointer; len: int): int {.nimcall.} = 0
proc stubProcKill(pid: uint32): int {.nimcall.} = 0
proc stubFsReadDir(path: cstring; buf: pointer; len: int): int {.nimcall.} = 0
proc stubFsRead(path: cstring; buf: pointer; len: int): int {.nimcall.} = 0
proc stubFsWrite(path: cstring; buf: pointer; len: int): int {.nimcall.} = 0
proc stubCapSend(name: cstring; tok: uint64; data: pointer; len: int): int {.nimcall.} = 0
proc stubChanCall(srv: cstring; data: pointer; dLen: int; rep: pointer; rLen: int): int {.nimcall.} = 0
proc stubSleep(ticks: uint64) {.nimcall.} = discard
proc stubYield() {.nimcall.} = discard
proc stubSysInfo(buf: pointer; len: int): int {.nimcall.} = 0
proc stubGrantRegion(slot: int; right: uint32): uint64 {.nimcall.} = 0
proc stubUptimeSecs(): uint64 {.nimcall.} = 0
proc stubWallClock(buf: pointer; len: int): int {.nimcall.} = 0
proc stubMapAnon(size: int): pointer {.nimcall.} = nil
proc stubFreeAnon(p: pointer; size: int) {.nimcall.} = discard
proc stubSndPlay(pcm: pointer; byteLen: int): int {.nimcall.} = 0
proc stubSndDrain(): int {.nimcall.} = 0
proc stubChanCreate(name: cstring): uint64 {.nimcall.} = 0
proc stubCapRecv(tok: uint64; buf: pointer; len: int): int {.nimcall.} = 0

proc fillStubVtable() =
  var v: abimod.NimixAbiVTable
  v.write          = stubWrite
  v.exit           = stubExit
  v.allocRegion    = stubAlloc
  v.freeRegion     = stubFree
  v.chanSend       = stubChanSend
  v.chanRecv       = stubChanRecv
  v.eventPublish   = stubEventPublish
  v.eventSubscribe = stubEventSubscribe
  v.eventPoll      = stubEventPoll
  v.getArgs        = stubGetArgs
  v.procList       = stubProcList
  v.schedStats     = stubSchedStats
  v.procKillPid    = stubProcKill
  v.fsReadDir      = stubFsReadDir
  v.fsRead         = stubFsRead
  v.fsWrite        = stubFsWrite
  v.capSend        = stubCapSend
  v.chanCall       = stubChanCall
  v.sleep          = stubSleep
  v.`yield`        = stubYield
  v.sysInfo        = stubSysInfo
  v.grantRegion    = stubGrantRegion
  v.uptimeSecs     = stubUptimeSecs
  v.wallClock      = stubWallClock
  v.mapAnon        = stubMapAnon
  v.freeAnon       = stubFreeAnon
  v.sndPlay        = stubSndPlay
  v.sndDrain       = stubSndDrain
  v.chanCreate     = stubChanCreate
  v.capRecv        = stubCapRecv
  v.bufCreate      = proc(size: int): int {.nimcall.} = 0
  v.bufMap         = proc(h: uint32): pointer {.nimcall.} = nil
  v.bufClose       = proc(h: uint32): int {.nimcall.} = 0
  v.bufSeal        = proc(h: uint32): int {.nimcall.} = 0
  v.bufReturn      = proc(h: uint32): int {.nimcall.} = 0
  v.bufMsgSend     = proc(name: cstring; data: pointer; dataLen: int; hs: pointer): int {.nimcall.} = 0
  v.bufMsgRecv     = proc(tok: uint64; buf: pointer; bufLen: int; hs: pointer): int {.nimcall.} = 0
  abimod.nimixAbi = v

proc testEnumOrdinals() =
  assert ord(scWrite)          ==  0
  assert ord(scExit)           ==  1
  assert ord(scAllocRegion)    ==  2
  assert ord(scFreeRegion)     ==  3
  assert ord(scChanSend)       ==  4
  assert ord(scChanRecv)       ==  5
  assert ord(scEventPublish)   ==  6
  assert ord(scEventSubscribe) ==  7
  assert ord(scEventPoll)      ==  8
  assert ord(scGetArgs)        ==  9
  assert ord(scProcList)       == 10
  assert ord(scSchedStats)     == 11
  assert ord(scProcKillPid)    == 12
  assert ord(scFsReadDir)      == 13
  assert ord(scFsRead)         == 14
  assert ord(scFsWrite)        == 15
  assert ord(scCapSend)        == 16
  assert ord(scChanCall)       == 17
  assert ord(scSleep)          == 18
  assert ord(scYield)          == 19
  assert ord(scSysInfo)        == 20
  assert ord(scGrantRegion)    == 21
  assert ord(scUptimeSecs)     == 22
  assert ord(scWallClock)      == 23
  assert ord(scMapAnon)        == 24
  assert ord(scFreeAnon)       == 25
  assert ord(scSndPlay)        == 26
  assert ord(scSndDrain)       == 27
  assert ord(scChanCreate)     == 28
  assert ord(scCapRecv)        == 29
  assert ord(scBufCreate)      == 30
  assert ord(scBufMsgRecv)     == 36
  assert NimixSyscallCount == 37
  echo "PASS: syscall enum ordinals"

proc testTableFilled() =
  fillStubVtable()
  syscallTableInit()
  for i in 0 ..< NimixSyscallCount:
    assert syscallTable[i] != 0, "syscallTable[" & $i & "] is zero after init"
  echo "PASS: all " & $NimixSyscallCount & " syscallTable entries non-zero after init"

proc testTableMatchesVtable() =
  fillStubVtable()
  syscallTableInit()
  assert syscallTable[ord(scWrite)]       == cast[uint64](stubWrite)
  assert syscallTable[ord(scExit)]        == cast[uint64](stubExit)
  assert syscallTable[ord(scUptimeSecs)]  == cast[uint64](stubUptimeSecs)
  assert syscallTable[ord(scWallClock)]   == cast[uint64](stubWallClock)
  assert syscallTable[ord(scMapAnon)]     == cast[uint64](stubMapAnon)
  assert syscallTable[ord(scFreeAnon)]    == cast[uint64](stubFreeAnon)
  assert syscallTable[ord(scSndPlay)]     == cast[uint64](stubSndPlay)
  assert syscallTable[ord(scSndDrain)]    == cast[uint64](stubSndDrain)
  assert syscallTable[ord(scChanCreate)]  == cast[uint64](stubChanCreate)
  assert syscallTable[ord(scCapRecv)]     == cast[uint64](stubCapRecv)
  echo "PASS: syscallTable pointers match vtable fields"

proc testSymbolsMatchCStubs() =
  ## Every patchable symbol must exist as a weak stub, or apps calling it get
  ## an unpatched (no-op) stub — or fail to link.
  const stubSrc = staticRead("../kernel/abi/nimix_abi_stub.c")
  var seen: seq[string]
  for sc in NimixSyscall:
    let name = $NimixSyscallSymbol[sc]
    assert name notin seen, "duplicate ABI symbol " & name
    seen.add name
    assert (" " & name & "(") in stubSrc, "no weak stub in nimix_abi_stub.c for " & name
  echo "PASS: all " & $NimixSyscallCount & " ABI symbols have weak C stubs"

proc testTrampolineBytes() =
  ## movabs rax, nr ; mov r10, rcx ; syscall ; ret — a complete 16-byte function.
  var buf: array[SyscallTrampolineLen, uint8]
  emitSyscallTrampoline(cast[uint64](addr buf[0]), uint64(ord(scCapRecv)))
  assert buf == [0x48'u8, 0xB8, 29, 0, 0, 0, 0, 0, 0, 0,
                 0x49, 0x89, 0xCA, 0x0F, 0x05, 0xC3], "trampoline encoding"
  echo "PASS: syscall trampoline encoding"

when isMainModule:
  testEnumOrdinals()
  testTableFilled()
  testTableMatchesVtable()
  testSymbolsMatchCStubs()
  testTrampolineBytes()
  echo "All syscall table tests passed."
