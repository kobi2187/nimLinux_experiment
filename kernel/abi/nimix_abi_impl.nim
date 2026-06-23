# SPDX-License-Identifier: GPL-2.0
## NimixOS ABI — kernel-side implementations (shared across all models).
##
## Memory (allocRegion/freeRegion) is model-specific; see each model's init.
## Everything else is wired here and reused by mono/micro/sasos.

import nimix_abi
import app_args
import ../../kernel/cap/capability as cap
import ../../core/serial
import ../../core/log
import ../../core/ptr_helpers
import ../../ipc/server_chan
import ../../kernel/event_server
import ../../kernel/traits/event
import ../../kernel/process_table
import ../../mm/region_allocator
import ../../drivers/pit

# ── I/O ───────────────────────────────────────────────────────────────────────

proc abiWrite*(buf: pointer; len: int) {.nimcall.} =
  if buf == nil or len <= 0: return
  let s = toBytes(buf)
  for i in 0 ..< len:
    defaultSerial.putChar(char(s[i]))

proc abiExit*(code: int) {.nimcall, noreturn.} =
  klogInt(llInfo, "app exit code: ", int64(code))
  kpanic("app exited")

# ── IPC: named channel ────────────────────────────────────────────────────────

proc abiChanSend*(name: cstring; data: pointer; dataLen: int): int {.nimcall.} =
  ## Post a message to the named ServerChan.
  ## Returns: 0=ok, -1=channel not found, -2=buffer full, -3=msg too large.
  let ch = serverChanFind($name)
  if ch == nil: return -1
  if dataLen > ServerMsgMaxLen: return -3
  var msg: ServerMsg
  msg.len = uint16(dataLen)
  copyBytes(addr msg.data[0], data, dataLen)
  if not serverChanPost(ch[], msg): return -2
  0

proc abiChanRecv*(name: cstring; buf: pointer; bufLen: int): int {.nimcall.} =
  ## Dequeue one message from the named ServerChan into buf.
  ## Returns bytes written, or -1 if empty/not found.
  let ch = serverChanFind($name)
  if ch == nil: return -1
  let m = serverChanRecv(ch[])
  if not m.hasValue: return -1
  let copyLen = copyBytesMin(buf, bufLen, addr m.value.data[0], int(m.value.len))
  copyLen

# ── IPC: event pub/sub ────────────────────────────────────────────────────────

proc abiEventPublish*(topic: cstring; data: pointer; dataLen: int) {.nimcall.} =
  eventPublish(topic, data, dataLen)

proc abiEventSubscribe*(topic: cstring): uint32 {.nimcall.} =
  uint32(eventSubscribe(topic))

proc abiEventPoll*(token: uint32; buf: pointer; bufLen: int): int {.nimcall.} =
  ## Poll for one event on token. Copies payload into buf.
  ## Returns payload bytes written, or -1 if no event pending.
  let ev = eventPoll(EventToken(token))
  if ev.isNone: return -1
  let payload = ev.get().payload
  let copyLen = copyBytesMin(buf, bufLen, unsafeAddr payload.data[0], int(payload.len))
  copyLen

# ── Process management ────────────────────────────────────────────────────────

proc abiGetArgs*(buf: pointer; len: int): int {.nimcall.} =
  ## Copy args for the currently-running app (keyed by regionSlot) into buf.
  let slot = int(procTable.tasks[procTable.current].regionSlot)
  getAppArgs(slot, buf, len)

# ── Text serialisation helpers (used by abiProcList / abiSchedStats) ─────────

proc bufEmit(dst: ptr UncheckedArray[char]; pos: var int; cap: int; s: cstring) =
  var i = 0
  while s[i] != '\0':
    if pos < cap - 1: dst[pos] = s[i]; inc pos
    inc i

proc bufEmitUInt(dst: ptr UncheckedArray[char]; pos: var int; cap: int; n: uint64) =
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

proc abiProcList*(buf: pointer; len: int): int {.nimcall.} =
  ## Serialize the process table as "pid class state name\n" lines.
  let dst = cast[ptr UncheckedArray[char]](buf)
  var pos = 0
  template emit(s: cstring)   = bufEmit(dst, pos, len, s)
  template emitU(n: uint64)   = bufEmitUInt(dst, pos, len, n)

  for i in 0 ..< MaxTasks:
    let t = procTable.tasks[i]
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

proc abiFsReadDir*(path: cstring; buf: pointer; len: int): int {.nimcall.} =
  ## Directory listing — not yet implemented.
  -1

proc abiChanCall*(server: cstring; data: pointer; dataLen: int;
                  replyBuf: pointer; replyBufLen: int): int {.nimcall.} =
  ## Synchronous IPC: send to server, spin-poll reply channel.
  let sendResult = abiChanSend(server, data, dataLen)
  if sendResult < 0: return sendResult
  var attempts = 0
  const MaxAttempts = 1_000_000
  while attempts < MaxAttempts:
    let n = abiChanRecv(server, replyBuf, replyBufLen)
    if n >= 0: return n
    inc attempts
  -1  # timeout

proc abiCapSend*(name: cstring; tok: uint64; data: pointer; dataLen: int): int {.nimcall.} =
  ## Capability-gated chanSend. Returns -3 if token is invalid or lacks capIpc.
  if not cap.capCheck(CapToken(tok), capIpc): return -3
  abiChanSend(name, data, dataLen)

# ── Scheduler ─────────────────────────────────────────────────────────────────

proc abiYield*() {.nimcall.} =
  ## Cooperative yield: update scheduler bookkeeping, let next ready task run.
  ## Without full RSP context switch this just updates state metadata.
  let next = procPickNext(procTable)
  if next >= 0 and next != procTable.current:
    let prev = procTable.current
    procTable.tasks[prev].state = ptsReady
    ringInsertTail(procTable, int16(prev), int(procTable.tasks[prev].class))
    procTable.current = next
    procTable.tasks[next].state = ptsRunning
    inc procTable.tasks[next].switches
    inc procTable.stats.totalSwitches

# ── System info ───────────────────────────────────────────────────────────────

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

# ── Timing ────────────────────────────────────────────────────────────────────

proc abiSleep*(ticks: uint64) {.nimcall.} =
  ## Cooperative sleep: spin-wait until ticks have elapsed.
  ## Replaced with real block+wake once context switch is complete.
  let target = pitTicks() + ticks
  procSleepUntil(int(procTable.current), target)
  # Spin until woken (PIT ISR fires and runs procWakeExpired)
  while procTable.tasks[procTable.current].state == ptsBlocked:
    discard
