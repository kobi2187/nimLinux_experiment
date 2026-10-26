# SPDX-License-Identifier: GPL-2.0
## NimixOS ABI — process management procs.
## Provides: abiGetArgs, abiProcList, abiSchedStats, abiProcKillPid.

import ../../kernel/process_table
import ../../mm/region_allocator
import app_args

proc bufEmit*(dst: ptr UncheckedArray[char]; pos: var int; cap: int; s: cstring) =
  var i = 0
  while s[i] != '\0':
    if pos < cap - 1: dst[pos] = s[i]; inc pos
    inc i

proc bufEmitUInt*(dst: ptr UncheckedArray[char]; pos: var int; cap: int; n: uint64) =
  if n == 0:
    if pos < cap - 1: dst[pos] = '0'; inc pos
    return
  var tmp: array[20, char]; var ti = 0; var v = n
  while v > 0:
    tmp[ti] = char(ord('0') + int(v mod 10)); inc ti
    v = v div 10
  while ti > 0:
    dec ti
    if pos < cap - 1: dst[pos] = tmp[ti]; inc pos

proc abiGetArgs*(buf: pointer; len: int): int {.nimcall.} =
  ## Copy args for the currently-running app (keyed by regionSlot) into buf.
  let slot = int(procTable.tasks[procTable.current].regionSlot)
  getAppArgs(slot, buf, len)

proc abiProcList*(buf: pointer; len: int): int {.nimcall.} =
  ## Serialize the process table as "pid class state name\n" lines.
  let dst = cast[ptr UncheckedArray[char]](buf)
  var pos = 0
  template emit(s: cstring)   = bufEmit(dst, pos, len, s)
  template emitU(n: uint64)   = bufEmitUInt(dst, pos, len, n)

  let totalTicks = procTable.stats.uptimeTicks
  for i in 0 ..< MaxTasks:
    let t = addr procTable.tasks[i]   # never copy a Task: it holds a 16 KB kstack
    if not t.used: continue
    emitU(uint64(t.pid)); emit(" ")
    case t.class
    of tcRealtime: emit("RT ")
    of tcServer:   emit("SV ")
    of tcApp:      emit("AP ")
    case t.state
    of ptsReady:   emit("ready   ")
    of ptsRunning: emit("running ")
    of ptsBlocked: emit("blocked ")
    of ptsZombie:  emit("zombie  ")
    let cpuPct = if totalTicks > 0: (t.cpuTicks * 100) div totalTicks else: 0
    emitU(cpuPct); emit("% ")
    emit(cast[cstring](unsafeAddr t.name[0])); emit("\n")

  if pos < len: dst[pos] = '\0'
  pos

proc abiSchedStats*(buf: pointer; len: int): int {.nimcall.} =
  ## Serialize scheduler stats as human-readable text.
  let dst = cast[ptr UncheckedArray[char]](buf)
  var pos = 0
  template emit(s: cstring)   = bufEmit(dst, pos, len, s)
  template emitU(n: uint64)   = bufEmitUInt(dst, pos, len, n)

  let s = procTable.stats
  emit("Uptime:   "); emitU(s.uptimeTicks);             emit(" ticks\n")
  emit("Switches: "); emitU(s.totalSwitches);            emit("\n")
  emit("Idle:     "); emitU(s.idleTicks);                emit(" ticks\n")
  emit("Tasks:    "); emitU(uint64(procTable.taskCount)); emit("\n")

  if pos < len: dst[pos] = '\0'
  pos

proc abiProcKillPid*(pid: uint32): int {.nimcall.} =
  ## Kill a task by PID. Frees its region. Returns 0=ok, -1=not found.
  let slot = procFindPid(pid)
  if slot < 0: return -1
  let regionSlot = procTable.tasks[slot].regionSlot
  discard procKill(slot)
  if regionSlot >= 0: regionFree(RegionHandle(regionSlot))
  0
