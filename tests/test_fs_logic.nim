# SPDX-License-Identifier: GPL-2.0
## Unit tests for fs_logic — pure logic, no kernel dependencies.

import ../servers/fs/fs_logic

# ── Mock implementations ──────────────────────────────────────────────────────

var mockBuf: array[4 * 1024 * 1024, byte]

proc mockAlloc(size: uint64): int {.nimcall.} = 0
proc mockFree(slot: int) {.nimcall.} = discard
proc mockBase(slot: int): uint64 {.nimcall.} = cast[uint64](addr mockBuf[0])
proc mockGrant(slot: int; pid: uint32; right: uint32): uint64 {.nimcall.} = 0xDEADBEEF'u64

proc mockReadFile(path: cstring; buf: pointer; len: int): (int, int) {.nimcall.} =
  let dst = cast[ptr UncheckedArray[byte]](buf)
  let msg = "hello"
  for i in 0 ..< msg.len:
    dst[i] = byte(msg[i])
  (0, 5)

proc mockReadFileFail(path: cstring; buf: pointer; len: int): (int, int) {.nimcall.} =
  (-1, 0)

proc mockAllocFail(size: uint64): int {.nimcall.} = -1

# ── Test helpers ──────────────────────────────────────────────────────────────

var passed = 0
var failed = 0

template check(cond: bool; msg: string) =
  if cond:
    inc passed
    echo "  PASS: " & msg
  else:
    inc failed
    echo "  FAIL: " & msg

# ── Tests ─────────────────────────────────────────────────────────────────────

echo "=== test_fs_logic ==="

# Test 1: happy path
block:
  echo "--- happy path ---"
  let iface = FsIface(
    readFile:  mockReadFile,
    allocSlot: mockAlloc,
    freeSlot:  mockFree,
    slotBase:  mockBase,
    grantCap:  mockGrant,
  )
  let reply = fsLogicRead(iface, "hello.txt", 0'u32, 4 * 1024 * 1024)
  check(reply.err == 0,              "err == 0")
  check(reply.token == 0xDEADBEEF'u64, "token == 0xDEADBEEF")
  check(reply.len == 5,              "len == 5")

# Test 2: alloc failure → err == -1
block:
  echo "--- alloc failure ---"
  let iface = FsIface(
    readFile:  mockReadFile,
    allocSlot: mockAllocFail,
    freeSlot:  mockFree,
    slotBase:  mockBase,
    grantCap:  mockGrant,
  )
  let reply = fsLogicRead(iface, "hello.txt", 0'u32, 4 * 1024 * 1024)
  check(reply.err == -1, "err == -1 on alloc failure")

# Test 3: readFile failure → err == -2
block:
  echo "--- readFile failure ---"
  let iface = FsIface(
    readFile:  mockReadFileFail,
    allocSlot: mockAlloc,
    freeSlot:  mockFree,
    slotBase:  mockBase,
    grantCap:  mockGrant,
  )
  let reply = fsLogicRead(iface, "missing.txt", 0'u32, 4 * 1024 * 1024)
  check(reply.err == -2, "err == -2 on readFile failure")

# Test 4: mock readFile returns (0, 42 bytes of 'X')
block:
  echo "--- 42-byte read ---"
  proc mockRead42(path: cstring; buf: pointer; len: int): (int, int) {.nimcall.} =
    let dst = cast[ptr UncheckedArray[byte]](buf)
    for i in 0 ..< 42:
      dst[i] = byte('X')
    (0, 42)
  let iface = FsIface(
    readFile:  mockRead42,
    allocSlot: mockAlloc,
    freeSlot:  mockFree,
    slotBase:  mockBase,
    grantCap:  mockGrant,
  )
  let reply = fsLogicRead(iface, "big.bin", 0'u32, 4 * 1024 * 1024)
  check(reply.err == 0,  "err == 0")
  check(reply.len == 42, "len == 42")
  check(reply.token != 0, "token != 0")

echo ""
echo "=== Results: " & $passed & " passed, " & $failed & " failed ==="
if failed > 0:
  quit(1)
