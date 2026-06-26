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
import ../../mm/region_allocator
import ../../drivers/pit
import ../../drivers/rtc
import ../../kernel/cap/capability as cap
import nimix_abi_proc
import nimix_abi_fs
import nimix_abi_sysinfo

export nimix_abi_proc
export nimix_abi_fs
export nimix_abi_sysinfo

# ── Scheduler helpers (needed before I/O procs that call them) ────────────────

proc currentSlot(): int {.inline.} = procTable.current

proc yieldToNext() =
  ## Hand the CPU to the next ready task in the scheduler ring.
  let next = procPickNext(procTable)
  if next >= 0 and next != procTable.current:
    let prev = procTable.current
    procTable.tasks[prev].state = ptsReady
    ringInsertTail(procTable, int16(prev), int(procTable.tasks[prev].class))
    procTable.current = next
    procTable.tasks[next].state = ptsRunning
    inc procTable.tasks[next].switches
    inc procTable.stats.totalSwitches

proc freeCurrentRegion() =
  ## Release the region slot owned by the current task (if any).
  let regionSlot = procTable.tasks[currentSlot()].regionSlot
  if regionSlot >= 0: regionFree(RegionHandle(regionSlot))

# ── I/O ───────────────────────────────────────────────────────────────────────

proc abiWrite*(buf: pointer; len: int) {.nimcall.} =
  if buf == nil or len <= 0: return
  let s = toBytes(buf)
  for i in 0 ..< len:
    defaultSerial.putChar(char(s[i]))

proc abiExit*(code: int) {.nimcall, noreturn.} =
  klogInt(llInfo, "app exit code: ", int64(code))
  freeCurrentRegion()
  discard procKill(currentSlot())
  yieldToNext()
  while true: discard  # unreachable; satisfies noreturn

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
  yieldToNext()

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

# ── RTC / wall clock ──────────────────────────────────────────────────────────

proc abiUptimeSecs*(): uint64 {.nimcall.} =
  ## Seconds since boot, from PIT tick counter.
  rtcUptimeSecs()

proc abiWallClock*(buf: pointer; len: int): int {.nimcall.} =
  ## Write "YYYY-MM-DD HH:MM:SS\n" into buf. Returns bytes written, or -1 if buf too small.
  let dt = rtcReadDateTime()
  # Format: "2026-06-26 09:15:30\n" = 20 chars
  if len < 20: return -1
  let p = cast[ptr array[32, char]](buf)
  proc d2(dst: ptr array[32, char]; off: int; v: uint16) =
    dst[off]   = char(ord('0') + int(v div 10))
    dst[off+1] = char(ord('0') + int(v mod 10))
  proc d4(dst: ptr array[32, char]; off: int; v: uint16) =
    dst[off]   = char(ord('0') + int(v div 1000))
    dst[off+1] = char(ord('0') + int((v div 100) mod 10))
    dst[off+2] = char(ord('0') + int((v div 10) mod 10))
    dst[off+3] = char(ord('0') + int(v mod 10))
  d4(p, 0, dt.year)
  p[4] = '-'
  d2(p, 5, dt.month.uint16)
  p[7] = '-'
  d2(p, 8, dt.day.uint16)
  p[10] = ' '
  d2(p, 11, dt.hour.uint16)
  p[13] = ':'
  d2(p, 14, dt.minute.uint16)
  p[16] = ':'
  d2(p, 17, dt.second.uint16)
  p[19] = '\n'
  20
