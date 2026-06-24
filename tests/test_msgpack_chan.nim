# SPDX-License-Identifier: GPL-2.0
## Unit tests for kernel/ipc/msgpack_chan — minimal MsgPack encoder/decoder.

import kernel/ipc/msgpack_chan

var passed = 0
var failed = 0

template check(cond: bool; msg: string) =
  if cond:
    echo "  PASS: ", msg
    inc passed
  else:
    echo "  FAIL: ", msg
    inc failed

# ── Test 1: encode a fixint map {op: 0x00000001, pid: 42} ────────────────────

block:
  echo "Test 1: encode uint32 map"
  var buf: MpBuf
  mpBeginMap(buf, 2)
  mpWriteStr(buf, "op")
  mpWriteUInt32(buf, 0x00000001'u32)
  mpWriteStr(buf, "pid")
  mpWriteUInt32(buf, 42'u32)
  check(buf.pos > 0, "buffer non-empty after encode")
  # fixmap(2)=0x82, fixstr(2)+"op"=0xA2,'o','p', fixint(1)=0x01
  # fixstr(3)+"pid"=0xA3,'p','i','d', fixint(42)=0x2A
  check(buf.pos == 10, "byte count == 10 for {op:1, pid:42}")

  # ── Decode
  var pos = 0
  let nkeys = mpMapLen(buf.data, pos)
  check(nkeys == 2, "map has 2 keys")

  # key "op"
  var strBuf: array[256, char]
  let klen1 = mpReadStr(buf.data, pos, strBuf)
  check(klen1 == 2, "key 'op' length == 2")
  check(strBuf[0] == 'o' and strBuf[1] == 'p', "key == 'op'")
  let opVal = mpReadUInt32(buf.data, pos)
  check(opVal == 1, "op round-trips as 1")

  # key "pid"
  let klen2 = mpReadStr(buf.data, pos, strBuf)
  check(klen2 == 3, "key 'pid' length == 3")
  check(strBuf[0] == 'p' and strBuf[1] == 'i' and strBuf[2] == 'd', "key == 'pid'")
  let pidVal = mpReadUInt32(buf.data, pos)
  check(pidVal == 42, "pid round-trips as 42")

# ── Test 2: large uint32 (> 255) encoding ────────────────────────────────────

block:
  echo "Test 2: uint32 > 255"
  var buf: MpBuf
  mpWriteUInt32(buf, 0xDEADBEEF'u32)
  check(buf.pos == 5, "uint32 tag(1) + 4 bytes")
  var pos = 0
  let v = mpReadUInt32(buf.data, pos)
  check(v == 0xDEADBEEF'u32, "0xDEADBEEF round-trips")

# ── Test 3: uint8 range (128-255) ────────────────────────────────────────────

block:
  echo "Test 3: uint8 range"
  var buf: MpBuf
  mpWriteUInt32(buf, 200'u32)
  check(buf.pos == 2, "uint8 tag(1) + 1 byte")
  var pos = 0
  let v = mpReadUInt32(buf.data, pos)
  check(v == 200, "200 round-trips")

# ── Test 4: string field "path" = "/boot/kernel.elf" ─────────────────────────

block:
  echo "Test 4: string field round-trip"
  var buf: MpBuf
  mpBeginMap(buf, 1)
  mpWriteStr(buf, "path")
  mpWriteStr(buf, "/boot/kernel.elf")

  var pos = 0
  let nkeys = mpMapLen(buf.data, pos)
  check(nkeys == 1, "map has 1 key")

  var strBuf: array[256, char]
  let klen = mpReadStr(buf.data, pos, strBuf)
  check(klen == 4, "key 'path' length == 4")

  let vlen = mpReadStr(buf.data, pos, strBuf)
  check(vlen == 16, "value length == 16")

  # Reconstruct string from array
  var s = ""
  for i in 0 ..< vlen: s.add(strBuf[i])
  check(s == "/boot/kernel.elf", "path value round-trips correctly")

# ── Test 5: mpSkipStr ─────────────────────────────────────────────────────────

block:
  echo "Test 5: mpSkipStr"
  var buf: MpBuf
  mpWriteStr(buf, "hello")
  mpWriteUInt32(buf, 99'u32)
  var pos = 0
  mpSkipStr(buf.data, pos)
  let v = mpReadUInt32(buf.data, pos)
  check(v == 99, "value after skipped string == 99")

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "Results: ", passed, " passed, ", failed, " failed"
if failed > 0:
  quit(1)
