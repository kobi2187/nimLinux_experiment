# SPDX-License-Identifier: GPL-2.0
## NimixOS ABI — shared implementations for write and exit.
##
## allocRegion / freeRegion differ per kernel model (see each model's init).
## write and exit are the same everywhere, defined once here.

import nimix_abi
import ../../core/serial
import ../../core/log

proc abiWrite*(buf: pointer; len: int) {.nimcall.} =
  ## Write raw bytes to serial + VGA. Used by all kernel models.
  if buf == nil or len <= 0: return
  let s = cast[ptr UncheckedArray[byte]](buf)
  for i in 0 ..< len:
    defaultSerial.putChar(char(s[i]))

proc abiExit*(code: int) {.nimcall, noreturn.} =
  ## App called nimixExit(). For now: panic with the exit code.
  ## Later: mark SIP/process as done and yield to scheduler.
  klogInt(llInfo, "app exit code: ", int64(code))
  kpanic("app exited")
