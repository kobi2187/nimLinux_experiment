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
import ../../mm/sip_heap
import ../../mm/region_allocator
import ../../mm/user_window
import ../../arch/x86_64/cpu_primitives
import ../../drivers/pit
import ../../drivers/rtc
import ../../drivers/virtio/virtio_snd
import ../../kernel/cap/capability as cap
import nimix_abi_proc
import nimix_abi_fs
import nimix_abi_sysinfo

export nimix_abi_proc
export nimix_abi_fs
export nimix_abi_sysinfo

# ── Scheduler helpers (needed before I/O procs that call them) ────────────────

proc currentSlot(): int {.inline.} = procTable.current

proc waitForTick() =
  ## Give the CPU away until the next PIT tick. Syscalls enter with IF=0
  ## (SFMASK), so a plain spin can never be preempted; enable interrupts, halt,
  ## and let pitIrqHandler perform the switch — the one switch path that saves
  ## and restores a full context. Masked again before returning to sysretq.
  sti()
  hlt()
  cli()

proc freeCurrentRegion() =
  ## Release the region slot owned by the current task (if any).
  let regionSlot = procTable.tasks[currentSlot()].regionSlot
  if regionSlot >= 0:
    discard appRegionUserAccess(RegionHandle(regionSlot), false)
    regionFree(RegionHandle(regionSlot))

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
  # The dead task is out of every ring; the next tick switches away for good.
  while true: waitForTick()

# ── IPC: named channel ────────────────────────────────────────────────────────

proc abiChanSend*(name: cstring; data: pointer; dataLen: int): int {.nimcall.} =
  ## Post a message to the named ServerChan.
  ## Returns: 0=ok, -1=channel not found, -2=buffer full, -3=msg too large.
  let ch = serverChanFind(name)
  if ch == nil: return -1
  if dataLen > ServerMsgMaxLen: return -3
  var msg: ServerMsg
  msg.len = uint16(dataLen)
  copyBytes(addr msg.data[0], data, dataLen)
  if not serverChanPost(ch[], msg): return -2
  0

proc recvInto(ch: ptr ServerChan; buf: pointer; bufLen: int): int =
  ## Dequeue one message into buf. Bytes written, or -1 if empty.
  let m = serverChanRecv(ch[])
  if not m.hasValue: return -1
  copyBytesMin(buf, bufLen, addr m.value.data[0], int(m.value.len))

proc abiChanRecv*(name: cstring; buf: pointer; bufLen: int): int {.nimcall.} =
  ## Dequeue one message from the named ServerChan into buf.
  ## Returns bytes written, -1 if empty/not found, -3 if the channel is
  ## server-owned (only its receive capability may drain it: abiCapRecv).
  let ch = serverChanFind(name)
  if ch == nil: return -1
  if ch.recvCap != 0: return -3
  recvInto(ch, buf, bufLen)

proc abiChanCreate*(name: cstring): uint64 {.nimcall.} =
  ## Create a named channel owned by the calling server. Returns its receive
  ## capability (capIpc), or 0 if the name is taken or no slot/cap is free.
  ## Senders keep addressing it by name; only the token holder can receive.
  if name == nil: return 0
  let pid = procTable.tasks[procTable.current].pid
  let tok = cap.capGrant(pid, capIpc)
  if tok.isNull: return 0
  if serverChanAllocOwned(name, uint64(tok)) == nil:
    cap.capRevoke(tok)
    return 0
  uint64(tok)

proc abiCapRecv*(tok: uint64; buf: pointer; bufLen: int): int {.nimcall.} =
  ## Receive on the channel bound to `tok`. Bytes written, -1 if empty,
  ## -3 if the token is invalid/revoked or bound to no channel.
  if not cap.capCheck(CapToken(tok), capIpc): return -3
  let ch = serverChanFindByCap(tok)
  if ch == nil: return -3
  recvInto(ch, buf, bufLen)

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
  ## Yield the rest of this quantum (round-robin picks the next ready task).
  waitForTick()

# ── Audio ─────────────────────────────────────────────────────────────────────

proc abiSndPlay*(pcm: pointer; byteLen: int): int {.nimcall.} =
  ## Submit a PCM buffer to virtio-snd. virtioSndPlay translates the pointer to a
  ## physical address internally, so we forward the region pointer as-is.
  ## Distinguish device-not-ready (-1) from ring-full backpressure (-2) so the
  ## streaming caller knows to drain and retry rather than give up.
  if pcm == nil or byteLen <= 0: return -1
  if virtioSndPlay(pcm, uint32(byteLen)): return 0
  if virtioSndTxFull(): -2 else: -1

proc abiSndDrain*(): int {.nimcall.} =
  ## Reclaim completed tx buffers; return in-flight count (0 = ring idle).
  discard virtioSndTxDrain()
  int(virtioSndInFlight())

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
  let me = int(procTable.current)
  procSleepUntil(me, target)
  while procTable.tasks[me].state == ptsBlocked:
    waitForTick()

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

# ── mmap-style heap growth ────────────────────────────────────────────────────

proc abiAllocRegion*(size: int): pointer {.nimcall.} =
  ## Ring-3 apps allocate from their OWN region (SIP bump heap) — never kernel
  ## heap memory, which is supervisor-only and not the app's to own. Kernel
  ## tasks (no region) use the kernel heap. Same in every kernel model.
  let slot = int(procTable.tasks[procTable.current].regionSlot)
  if slot < 0: return alloc(size)
  sipAlloc(slot, size)

proc abiFreeRegion*(p: pointer; size: int) {.nimcall.} =
  ## Kernel-task memory is returned to the kernel heap; app-region memory is a
  ## bump heap reclaimed whole when the app exits.
  if p == nil: return
  if procTable.tasks[procTable.current].regionSlot < 0: dealloc(p)

proc abiMapAnon*(size: int): pointer {.nimcall.} =
  ## Allocate `size` bytes from the calling app's SIP bump heap.
  ## Returns nil if size <= 0 or the task has no region.
  assert size > 0, "mapAnon: size must be positive"
  let slot = int(procTable.tasks[procTable.current].regionSlot)
  if slot < 0: return nil
  sipAlloc(slot, size)

proc abiFreeAnon*(p: pointer; size: int) {.nimcall.} =
  ## No-op: bump allocator; the region is freed whole on nimixExit.
  discard
