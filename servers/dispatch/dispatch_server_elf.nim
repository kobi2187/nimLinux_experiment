# SPDX-License-Identifier: GPL-2.0
## Dispatcher PIE ELF server — listens on "dispatch" channel, runs CPS loop.
## Compiled with --os:any --mm:arc --panics:on: nim-cps needs
## getCurrentException, which system.nim omits under --os:standalone.

import dispatch_logic
import nimix_common   # write, nimixWrite, nimixExit, nimixGetArgs

# ABI imports for server use
proc nimixChanSend(name: cstring; data: pointer; len: int): int {.importc, cdecl.}
proc nimixChanRecv(name: cstring; buf: pointer; len: int): int {.importc, cdecl.}
proc nimixSleep(ticks: uint64) {.importc, cdecl.}

proc elfSend(ch: cstring; data: pointer; len: int): int {.nimcall.} =
  nimixChanSend(ch, data, len)

proc elfRecv(ch: cstring; buf: pointer; len: int): int {.nimcall.} =
  nimixChanRecv(ch, buf, len)

proc elfSleep(ticks: uint64) {.nimcall.} =
  nimixSleep(ticks)

proc elfLog(msg: cstring) {.nimcall.} =
  var i = 0
  while msg[i] != '\0': inc i
  nimixWrite(cast[pointer](msg), i)

var gState: DispatchState

proc appMain*() {.exportc.} =
  write("dispatcher: starting\n")
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
