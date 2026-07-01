# SPDX-License-Identifier: GPL-2.0
## Host-side test for audio_server pure logic (servers/media/audio_logic.nim).
## Uses a recording stub sink — no kernel, no QEMU.

import servers/media/audio_logic
import unittest

# Recording stub: capture what the logic asked the sink to do.
var lastPcm: pointer
var lastLen: uint32
var playCalls: int
var stopCalls: int
var drainCalls: int
var yieldCalls: int
var totalQueued: uint32
var lastVol: uint8

proc resetStub() =
  lastPcm = nil; lastLen = 0; playCalls = 0; stopCalls = 0
  drainCalls = 0; yieldCalls = 0; totalQueued = 0; lastVol = 0

proc stubPlay(pcm: pointer; byteLen: uint32): int {.nimcall.} =
  lastPcm = pcm; lastLen = byteLen; inc playCalls; totalQueued += byteLen; 0

proc stubPlayFail(pcm: pointer; byteLen: uint32): int {.nimcall.} =
  -1   # device not ready

# Full-then-drain: first N calls report ring full (-2), then accept.
var fullBudget: int
proc stubPlayBackpressure(pcm: pointer; byteLen: uint32): int {.nimcall.} =
  inc playCalls
  if fullBudget > 0: dec fullBudget; return -2   # ring full
  totalQueued += byteLen; 0

proc stubDrain(): int {.nimcall.} = inc drainCalls; 0
proc stubYield() {.nimcall.} = inc yieldCalls
proc stubStop(): int {.nimcall.} = inc stopCalls; 0
proc stubVolume(level: uint8): int {.nimcall.} = lastVol = level; 0

proc okIface(): AudioIface =
  AudioIface(play: stubPlay, drain: stubDrain, wait: stubYield,
             stop: stubStop, volume: stubVolume)

const S16Stereo = MediaFormat(rate: 44100, channels: 2, bits: 16)

suite "audio_server logic":
  test "Play routes a small PCM region as one chunk":
    resetStub()
    var pcm = [1'u8, 2, 3, 4]
    let req = MediaRequest(op: uint32(moPlay), pid: 7,
                           base: cast[uint64](addr pcm[0]), len: 4, fmt: S16Stereo)
    let r = okIface().audioHandle(req)
    check r.err == ErrOk
    check r.queued == 4
    check playCalls == 1
    check lastLen == 4

  test "Large region is streamed in ChunkBytes pieces":
    resetStub()
    let total = ChunkBytes * 3 + 100        # 3 full chunks + a remainder
    let req = MediaRequest(op: uint32(moPlay), pid: 7,
                           base: 0x10000'u64, len: total, fmt: S16Stereo)
    let r = okIface().audioHandle(req)
    check r.err == ErrOk
    check r.queued == total
    check playCalls == 4                    # 3 full + 1 partial
    check totalQueued == total
    check lastLen == 100                    # last chunk is the remainder

  test "Backpressure: ring full drains and retries, no data lost":
    resetStub()
    fullBudget = 2                          # first 2 submits report ring full
    let iface = AudioIface(play: stubPlayBackpressure, drain: stubDrain,
                           wait: stubYield, stop: stubStop, volume: stubVolume)
    let req = MediaRequest(op: uint32(moPlay), pid: 7,
                           base: 0x20000'u64, len: 200, fmt: S16Stereo)
    let r = iface.audioHandle(req)
    check r.err == ErrOk
    check r.queued == 200                   # all bytes eventually queued
    check drainCalls == 2                   # drained once per full report
    check yieldCalls == 2                   # yielded while waiting
    check playCalls == 3                    # 2 rejected + 1 accepted

  test "Play with empty region is rejected":
    resetStub()
    let req = MediaRequest(op: uint32(moPlay), pid: 1, base: 0, len: 0, fmt: S16Stereo)
    let r = okIface().audioHandle(req)
    check r.err == ErrBadRequest
    check playCalls == 0

  test "Unsupported format is rejected explicitly":
    resetStub()
    var pcm = [0'u8, 0, 0, 0]
    let badFmt = MediaFormat(rate: 44100, channels: 2, bits: 24)  # 24-bit not wired
    let req = MediaRequest(op: uint32(moPlay), pid: 1,
                           base: cast[uint64](addr pcm[0]), len: 4, fmt: badFmt)
    let r = okIface().audioHandle(req)
    check r.err == ErrUnsupportedOp
    check playCalls == 0

  test "Device-not-ready surfaces as error":
    resetStub()
    var pcm = [0'u8, 0, 0, 0]
    let iface = AudioIface(play: stubPlayFail, stop: stubStop, volume: stubVolume)
    let req = MediaRequest(op: uint32(moPlay), pid: 1,
                           base: cast[uint64](addr pcm[0]), len: 4, fmt: S16Stereo)
    let r = iface.audioHandle(req)
    check r.err == ErrDeviceNotReady

  test "Stop and SetVolume route to their sinks":
    resetStub()
    discard okIface().audioHandle(MediaRequest(op: uint32(moStop), pid: 1))
    check stopCalls == 1
    discard okIface().audioHandle(MediaRequest(op: uint32(moSetVolume), pid: 1, len: 200))
    check lastVol == 200

echo "=== All audio_logic tests passed ==="
