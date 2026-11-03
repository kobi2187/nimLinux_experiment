# SPDX-License-Identifier: GPL-2.0
## Dispatcher PIE ELF server — listens on "dispatch" channel, runs CPS loop.
## Compiled with --os:any --mm:arc --panics:on: nim-cps needs
## getCurrentException, which system.nim omits under --os:standalone.

import dispatch_logic
import nimix_common   # write, nimixWrite, nimixExit, nimixGetArgs
import nimix_entry

# ABI imports for server use
proc nimixChanSend(name: cstring; data: pointer; len: int): int {.importc, cdecl.}
proc nimixSleep(ticks: uint64) {.importc, cdecl.}
proc nimixChanCreate(name: cstring): uint64 {.importc, cdecl.}
proc nimixCapRecv(tok: uint64; buf: pointer; len: int): int {.importc, cdecl.}

var gRecvCap: uint64   ## receive capability for our own "dispatch" channel

proc elfSend(ch: cstring; data: pointer; len: int): int {.nimcall.} =
  nimixChanSend(ch, data, len)

proc elfRecv(ch: cstring; buf: pointer; len: int): int {.nimcall.} =
  ## The dispatcher owns its channel: receive through the capability, not the
  ## name (a plain nimixChanRecv on an owned channel is refused with -3).
  nimixCapRecv(gRecvCap, buf, len)

proc elfSleep(ticks: uint64) {.nimcall.} =
  nimixSleep(ticks)

proc elfLog(msg: cstring) {.nimcall.} =
  var i = 0
  while msg[i] != '\0': inc i
  nimixWrite(cast[pointer](msg), i)

var gState: DispatchState

proc appMain*() {.exportc.} =
  nimixAppInit()   # module init first: --noMain skips it (nimix_entry)
  write("dispatcher: starting\n")
  gRecvCap = nimixChanCreate(DispatchChannel)
  if gRecvCap == 0:
    write("dispatcher: channel 'dispatch' unavailable (taken?) - exiting\n")
    nimixExit(1)
  let iface = DispatchIface(
    send:  elfSend,
    recv:  elfRecv,
    sleep: elfSleep,
    log:   elfLog
  )
  dispatchInit(gState, iface)
  let actor = newDispatcher(addr gState)
  write("dispatcher: ready on 'dispatch' channel\n")
  # Main loop: one pump per quantum (inbound requests → actor, then tick)
  while true:
    discard dispatchPump(addr gState, actor)
    nimixSleep(1)   # yield every tick
