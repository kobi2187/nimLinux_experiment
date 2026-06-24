# SPDX-License-Identifier: GPL-2.0
## NimixOS ABI — abiSysInfo: YAML system snapshot.

import ../../kernel/process_table
import ../../mm/region_allocator
import nimix_abi_proc  # bufEmit, bufEmitUInt

proc abiSysInfo*(buf: pointer; len: int): int {.nimcall.} =
  ## Emit a YAML system snapshot into buf. Returns bytes written.
  let dst = cast[ptr UncheckedArray[char]](buf)
  var pos = 0
  template emit(s: cstring)  = bufEmit(dst, pos, len, s)
  template emitU(n: uint64)  = bufEmitUInt(dst, pos, len, n)

  let s = procTable.stats
  let upSec = s.uptimeTicks div 100

  emit("---\n")
  emit("uptime_ticks: ");    emitU(s.uptimeTicks);                          emit("\n")
  emit("uptime_sec: ");      emitU(upSec);                                  emit("\n")
  emit("total_switches: ");  emitU(s.totalSwitches);                        emit("\n")
  emit("idle_ticks: ");      emitU(s.idleTicks);                            emit("\n")
  emit("task_count: ");      emitU(uint64(procTable.taskCount));             emit("\n")
  emit("regions_used: ");    emitU(uint64(regionUsedCount()));               emit("\n")
  emit("regions_total: ");   emitU(uint64(MaxRegions));                     emit("\n")
  emit("cpu_by_class:\n")
  emit("  realtime: ");      emitU(s.ticksPerClass[0]);                     emit("\n")
  emit("  server: ");        emitU(s.ticksPerClass[1]);                     emit("\n")
  emit("  app: ");           emitU(s.ticksPerClass[2]);                     emit("\n")
  emit("tasks:\n")
  for i in 0 ..< MaxTasks:
    let t = procTable.tasks[i]
    if not t.used: continue
    emit("  - pid: ");    emitU(uint64(t.pid));                             emit("\n")
    emit("    name: ");   emit(cast[cstring](unsafeAddr t.name[0]));        emit("\n")
    emit("    class: ")
    case t.class
    of tcRealtime: emit("realtime\n")
    of tcServer:   emit("server\n")
    of tcApp:      emit("app\n")
    emit("    state: ")
    case t.state
    of ptsReady:   emit("ready\n")
    of ptsRunning: emit("running\n")
    of ptsBlocked: emit("blocked\n")
    of ptsZombie:  emit("zombie\n")
    emit("    switches: ");   emitU(t.switches);                            emit("\n")
    emit("    cpu_ticks: ");  emitU(t.cpuTicks);                            emit("\n")

  if pos < len: dst[pos] = '\0'
  pos
