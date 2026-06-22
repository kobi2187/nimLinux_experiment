# SPDX-License-Identifier: GPL-2.0
## NimixOS ABI — kernel-side implementations (shared across all models).
##
## Memory (allocRegion/freeRegion) is model-specific; see each model's init.
## Everything else is wired here and reused by mono/micro/sasos.

import nimix_abi
import ../../core/serial
import ../../core/log
import ../../ipc/server_chan
import ../../kernel/event_server
import ../../kernel/traits/event

# ── I/O ───────────────────────────────────────────────────────────────────────

proc abiWrite*(buf: pointer; len: int) {.nimcall.} =
  if buf == nil or len <= 0: return
  let s = cast[ptr UncheckedArray[byte]](buf)
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
  let src = cast[ptr UncheckedArray[byte]](data)
  for i in 0 ..< dataLen:
    msg.data[i] = src[i]
  if not serverChanPost(ch[], msg): return -2
  0

proc abiChanRecv*(name: cstring; buf: pointer; bufLen: int): int {.nimcall.} =
  ## Dequeue one message from the named ServerChan into buf.
  ## Returns bytes written, or -1 if empty/not found.
  let ch = serverChanFind($name)
  if ch == nil: return -1
  let m = serverChanRecv(ch[])
  if not m.hasValue: return -1
  let copyLen = if int(m.value.len) < bufLen: int(m.value.len) else: bufLen
  let dst = cast[ptr UncheckedArray[byte]](buf)
  for i in 0 ..< copyLen:
    dst[i] = m.value.data[i]
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
  let plen = int(payload.len)
  let copyLen = if plen < bufLen: plen else: bufLen
  let dst = cast[ptr UncheckedArray[byte]](buf)
  let src = cast[ptr UncheckedArray[byte]](unsafeAddr payload.data[0])
  for i in 0 ..< copyLen:
    dst[i] = src[i]
  copyLen
