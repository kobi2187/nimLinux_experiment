# SPDX-License-Identifier: GPL-2.0
## Tests for chanCall — synchronous IPC (send + spin-wait reply).
##
## Uses -d:testing to inject mock abiChanSend/abiChanRecv instead of
## the real kernel implementations that require hardware.

when not defined(testing):
  {.error: "compile with -d:testing".}

# ── Mock state ────────────────────────────────────────────────────────────────

var mockSendResult*  = 0      ## value returned by mock abiChanSend
var mockRecvCounter* = 0      ## how many times abiChanRecv has been called
var mockRecvAfter*   = 0      ## return a valid reply only after this many calls
var mockReplyPayload* = "ok"  ## payload written into replyBuf on success

proc abiChanSend(name: cstring; data: pointer; dataLen: int): int =
  mockSendResult

proc abiChanRecv(name: cstring; buf: pointer; bufLen: int): int =
  inc mockRecvCounter
  if mockRecvCounter > mockRecvAfter:
    # write payload into buf
    let dst = cast[ptr UncheckedArray[byte]](buf)
    let src = mockReplyPayload
    let n   = if src.len < bufLen: src.len else: bufLen
    for i in 0 ..< n:
      dst[i] = byte(src[i])
    return n
  -1  # not ready yet

# ── chanCall implementation (copy of abiChanCall logic, using mock procs) ────

proc chanCall(server: cstring; data: pointer; dataLen: int;
              replyBuf: pointer; replyBufLen: int): int =
  let sendResult = abiChanSend(server, data, dataLen)
  if sendResult < 0: return sendResult
  var attempts = 0
  const MaxAttempts = 1_000_000
  while attempts < MaxAttempts:
    let n = abiChanRecv(server, replyBuf, replyBufLen)
    if n >= 0: return n
    inc attempts
  -1  # timeout

# ── Tests ─────────────────────────────────────────────────────────────────────

proc testChanCallSucceedsFirstTry() =
  ## Reply arrives on the very first recv poll — should return payload length.
  mockSendResult   = 0
  mockRecvCounter  = 0
  mockRecvAfter    = 0   # first call returns data
  mockReplyPayload = "hello"

  var buf: array[64, byte]
  let req = "ping"
  let n = chanCall("echo", cast[pointer](unsafeAddr req[0]), req.len,
                   cast[pointer](addr buf[0]), buf.len)
  assert n == 5, "expected 5 bytes reply, got " & $n
  assert buf[0] == byte('h'), "buf[0] should be 'h'"
  assert buf[4] == byte('o'), "buf[4] should be 'o'"
  echo "PASS: chanCall succeeds on first try"

proc testChanCallSucceedsAfterRetries() =
  ## Reply arrives after a few polls — still succeeds.
  mockSendResult   = 0
  mockRecvCounter  = 0
  mockRecvAfter    = 3   # polls 1-3 return -1, poll 4 returns data
  mockReplyPayload = "ack"

  var buf: array[64, byte]
  let req = "x"
  let n = chanCall("svc", cast[pointer](unsafeAddr req[0]), req.len,
                   cast[pointer](addr buf[0]), buf.len)
  assert n == 3, "expected 3 bytes, got " & $n
  assert mockRecvCounter == 4, "expected 4 recv calls, got " & $mockRecvCounter
  echo "PASS: chanCall succeeds after retries"

proc testChanCallFailsWhenSendFails() =
  ## If abiChanSend returns -1, chanCall must propagate that immediately.
  mockSendResult  = -1
  mockRecvCounter = 0

  var buf: array[64, byte]
  let req = "z"
  let n = chanCall("gone", cast[pointer](unsafeAddr req[0]), req.len,
                   cast[pointer](addr buf[0]), buf.len)
  assert n == -1, "expected -1 when send fails, got " & $n
  assert mockRecvCounter == 0, "recv must not be called when send fails"
  echo "PASS: chanCall propagates send failure"

proc testChanCallTimesOut() =
  ## If recv never returns data within MaxAttempts, chanCall returns -1.
  ## We use a patched MaxAttempts via a tiny wrapper so the test runs fast.
  mockSendResult   = 0
  mockRecvCounter  = 0
  mockRecvAfter    = high(int)  # never return data

  # Use a small-MaxAttempts version inline:
  proc chanCallShort(server: cstring; data: pointer; dataLen: int;
                     replyBuf: pointer; replyBufLen: int): int =
    let sr = abiChanSend(server, data, dataLen)
    if sr < 0: return sr
    var attempts = 0
    const MaxAttempts = 10  # tiny limit for test speed
    while attempts < MaxAttempts:
      let nr = abiChanRecv(server, replyBuf, replyBufLen)
      if nr >= 0: return nr
      inc attempts
    -1

  var buf: array[64, byte]
  let req = "q"
  let n = chanCallShort("deaf", cast[pointer](unsafeAddr req[0]), req.len,
                        cast[pointer](addr buf[0]), buf.len)
  assert n == -1, "expected -1 on timeout, got " & $n
  echo "PASS: chanCall times out and returns -1"

when isMainModule:
  testChanCallSucceedsFirstTry()
  testChanCallSucceedsAfterRetries()
  testChanCallFailsWhenSendFails()
  testChanCallTimesOut()
  echo "All sync IPC tests passed."
