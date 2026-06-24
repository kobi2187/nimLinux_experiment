# SPDX-License-Identifier: GPL-2.0
## NimixOS ABI — kernel-side implementations (shared across all models).
##
## Memory (allocRegion/freeRegion) is model-specific; see each model's init.
## Everything else is wired here and reused by mono/micro/sasos.

import ../../core/serial
import ../../core/log
import ../../core/ptr_helpers
import ../../ipc/server_chan
import ../../kernel/event_server
import ../../kernel/traits/event
import ../../kernel/process_table
import ../../drivers/pit
import ../../kernel/cap/capability as cap
import nimix_abi_proc
import nimix_abi_fs
import nimix_abi_sysinfo

export nimix_abi_proc
export nimix_abi_fs
export nimix_abi_sysinfo

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

# ── Scheduler ─────────────────────────────────────────────────────────────────

proc abiYield*() {.nimcall.} =
  ## Cooperative yield: update scheduler bookkeeping, let next ready task run.
  let next = procPickNext(procTable)
  if next >= 0 and next != procTable.current:
    let prev = procTable.current
    procTable.tasks[prev].state = ptsReady
    ringInsertTail(procTable, int16(prev), int(procTable.tasks[prev].class))
    procTable.current = next
    procTable.tasks[next].state = ptsRunning
    inc procTable.tasks[next].switches
    inc procTable.stats.totalSwitches

# ── Timing ────────────────────────────────────────────────────────────────────

proc abiGrantRegion*(slot: int; right: uint32): uint64 {.nimcall.} =
  ## Mint a memory cap for the current task.
  let pid = procTable.tasks[procTable.current].pid
  let capRight = cap.CapRight(right)
  let tok = cap.capGrantRegion(slot, pid, capRight)
  uint64(tok)

proc abiSleep*(ticks: uint64) {.nimcall.} =
  ## Cooperative sleep: spin-wait until ticks have elapsed.
  let target = pitTicks() + ticks
  procSleepUntil(int(procTable.current), target)
  while procTable.tasks[procTable.current].state == ptsBlocked:
    discard
