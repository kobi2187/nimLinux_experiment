# SPDX-License-Identifier: GPL-2.0
## Dispatcher kernel module — monolithic model variant.
## Wires kernel ABI into DispatchIface and runs the dispatch loop.

import dispatch_logic

# Kernel ABI — resolved at link time in monolithic build
proc nimixAbiChanSend(name: cstring; data: pointer; len: int): int {.importc: "nimixChanSend", cdecl.}
proc nimixAbiChanRecv(name: cstring; buf: pointer; len: int): int {.importc: "nimixChanRecv", cdecl.}
proc nimixAbiSleep(ticks: uint64) {.importc: "nimixSleep", cdecl.}
proc nimixAbiWrite(buf: pointer; len: int) {.importc: "nimixWrite", cdecl.}

proc cstringLen(s: cstring): int =
  var i = 0
  while s[i] != '\0': inc i
  i

var gDispatchState: DispatchState

proc kmodSend(ch: cstring; data: pointer; len: int): int {.nimcall.} =
  nimixAbiChanSend(ch, data, len)

proc kmodRecv(ch: cstring; buf: pointer; len: int): int {.nimcall.} =
  nimixAbiChanRecv(ch, buf, len)

proc kmodSleep(ticks: uint64) {.nimcall.} =
  nimixAbiSleep(ticks)

proc kmodLog(msg: cstring) {.nimcall.} =
  nimixAbiWrite(cast[pointer](msg), cstringLen(msg))

proc dispatchKmodInit*() =
  let iface = DispatchIface(
    send:  kmodSend,
    recv:  kmodRecv,
    sleep: kmodSleep,
    log:   kmodLog
  )
  dispatchInit(gDispatchState, iface)
