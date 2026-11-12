# SPDX-License-Identifier: GPL-2.0
## devtest — exercise one virtio device so the HOST can verify real effect.
##
##   devtest gpu    four colour bars, presented   → QMP screendump pixels
##   devtest snd    0.5 s 440 Hz square wave      → QEMU wav recording
##   devtest net    UDP frame to the gateway      → QEMU pcap capture
##   devtest input  print input events for ~5 s   → keys injected via QMP
##   devtest crash-pf|crash-ud|crash-panic         → crash report + backtrace
##                  on serial (halts!), symbolized by tools/symbolize.py
##
## Driven by tests/qemu_devices.py; also handy interactively.

import ../core/serial
import ../drivers/pit
import ../drivers/virtio/virtio_gpu
import ../drivers/virtio/virtio_snd
import ../drivers/virtio/virtio_net
import ../drivers/virtio/virtio_input
import ../drivers/net/ethernet
import ../drivers/net/ipv4
import ../drivers/net/udp
import ../kernel/event_server
import ../arch/x86_64/cpu_primitives

const
  BarColors* = [0x00FF0000'u32, 0x0000FF00'u32, 0x000000FF'u32, 0x00FFFFFF'u32]
  NetMarker* = "NIMIXOS-DEVTEST"
  ToneHz     = 440
  SampleRate = 44100
  ChunkBytes = int(SndPeriodBytes)
  # ~0.5 s rounded up to whole periods (the device holds a partial one back).
  ToneFrames = (SampleRate * 2 + ChunkBytes - 1) div ChunkBytes * ChunkBytes div 4

var toneBuf: array[ToneFrames * 4, byte]  # S16LE stereo, identity-mapped (DMA-able)
var frameBuf: array[128, byte]

proc say(s: string) =
  for c in s: defaultSerial.putChar(c)

proc sayInt(n: int64) =
  if n < 0:
    defaultSerial.putChar('-'); sayInt(-n); return
  if n >= 10: sayInt(n div 10)
  defaultSerial.putChar(char(ord('0') + int(n mod 10)))

proc testGpu() =
  let fb = virtioGpuFbPtr()
  if fb == nil:
    say("devtest gpu: not available\n"); return
  let w = int(gGpu.width)
  let h = int(gGpu.height)
  for y in 0 ..< h:
    for x in 0 ..< w:
      fb[y * w + x] = BarColors[min(x * 4 div w, 3)]
  virtioGpuPresent()
  say("devtest gpu: "); sayInt(w); say("x"); sayInt(h); say(" bars presented\n")

proc testSnd() =
  if not gSnd.ready:
    say("devtest snd: not available\n"); return
  let half = SampleRate div (2 * ToneHz)   # samples per half period
  for i in 0 ..< ToneFrames:
    let v = if (i div half) mod 2 == 0: 8000'i16 else: -8000'i16
    for ch in 0 .. 1:
      let o = (i * 2 + ch) * 2
      toneBuf[o] = byte(uint16(v) and 0xFF)
      toneBuf[o + 1] = byte(uint16(v) shr 8)
  var off = 0
  while off < toneBuf.len:
    let n = min(ChunkBytes, toneBuf.len - off)
    if virtioSndPlay(addr toneBuf[off], uint32(n)): off += n
    else: discard virtioSndTxDrain()
  let deadline = pitTicks() + 300            # 3 s
  while virtioSndInFlight() > 1 and pitTicks() < deadline:
    discard virtioSndTxDrain()
    hlt()
  discard virtioSndFinish()
  say("devtest snd: played "); sayInt(toneBuf.len); say(" bytes, in flight ")
  sayInt(int64(virtioSndInFlight())); say("\n")

proc testNet() =
  if not gVirtioNetReady:
    say("devtest net: not available\n"); return
  let src = ipAddr(10, 0, 2, 15)            # QEMU user-net guest address
  let dst = ipAddr(10, 0, 2, 2)             # QEMU user-net gateway
  let broadcast: EthAddr = [0xFF'u8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
  var payload: array[NetMarker.len, byte]
  for i, c in NetMarker: payload[i] = byte(c)
  let udpLen = udpEncode(addr frameBuf[EthHdrLen + IpHdrLen], 40000, 9,
                         addr payload[0], payload.len)
  let ipLen = ipEncode(addr frameBuf[EthHdrLen], src, dst, 17, udpLen)
  let total = ethEncode(addr frameBuf[0], broadcast, gVirtioNet.mac, 0x0800, ipLen)
  if virtioNetSend(addr frameBuf[0], uint32(total)):
    say("devtest net: sent "); sayInt(total); say(" byte UDP frame\n")
  else:
    say("devtest net: send failed\n")

proc testInput() =
  if gInputCount == 0:
    say("devtest input: not available\n"); return
  let tok = eventSubscribe("input")
  say("devtest input: listening 5 s\n")
  let deadline = pitTicks() + 500
  var seen = 0
  while pitTicks() < deadline and seen < 32:
    let ev = eventPoll(tok)
    if ev.isSome:
      let p = ev.get().payload
      let typ  = uint16(p.data[0]) or (uint16(p.data[1]) shl 8)
      let code = uint16(p.data[2]) or (uint16(p.data[3]) shl 8)
      let val  = uint32(p.data[4]) or (uint32(p.data[5]) shl 8)
      if typ == 1:                            # EV_KEY (skip EV_SYN frames); buttons are keys too
        say("input: key code="); sayInt(int64(code)); say(" value="); sayInt(int64(val)); say("\n")
      elif typ == 2 or typ == 3:              # EV_REL (mouse) / EV_ABS (tablet)
        say(if typ == 2: "input: rel code=" else: "input: abs code="); sayInt(int64(code))
        say(" value="); sayInt(int64(cast[int32](uint32(p.data[4]) or (uint32(p.data[5]) shl 8) or
                                          (uint32(p.data[6]) shl 16) or (uint32(p.data[7]) shl 24)))); say("\n")
      inc seen
    else:
      hlt()
  eventUnsubscribe(tok)
  say("devtest input: done, events="); sayInt(seen); say(" devices="); sayInt(int64(gInputCount)); say(" irq-events="); sayInt(int64(gInputs[0].evCount)); say("\n")

proc crashPageFault() {.noinline.} =
  let p = cast[ptr uint64](0x7FFF_DEAD_0000'u64)   # unmapped
  p[] = 1

proc crashInvalidOpcode() {.noinline.} =
  {.emit: "asm volatile(\"ud2\");".}

proc crashPanic(n: int) {.noinline.} =
  var a = [1, 2, 3]
  say("devtest crash-panic: indexing ["); sayInt(n); say("]\n")
  a[n] = 4                                     # IndexDefect → panic()

proc devtest*(what: openArray[char]) =
  var name = ""
  for c in what:
    if c == '\0': break
    name.add c
  case name
  of "gpu":   testGpu()
  of "snd":   testSnd()
  of "net":   testNet()
  of "input": testInput()
  of "crash-pf":    crashPageFault()
  of "crash-ud":    crashInvalidOpcode()
  of "crash-panic": crashPanic(int(pitTicks() mod 2) + 7)   # not constant-folded
  else: say("usage: devtest gpu|snd|net|input|crash-pf|crash-ud|crash-panic\n")
