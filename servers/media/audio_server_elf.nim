# SPDX-License-Identifier: GPL-2.0
## audio_server — userspace ELF (ring-3 PIE), category-2 "media" server.
##
## Position in the pipeline:
##   user app ──▶ dispatcher ("media" chan, op top-byte=2) ──▶ audio_server
##                    (QoS / log / profile)                        │
##                                                                 ▼
##                                              decode / mix / resample  (userspace libs)
##                                                                 │
##                                                                 ▼
##                                                    sndPlay ABI ─▶ kernel ─▶ virtio-snd
##   user app ◀── dispatcher ◀──────────────── MediaReply ◀────────┘
##
## The app grants a region holding *encoded* audio (or raw PCM); the server owns
## the decode libraries (dr_libs / stb_vorbis, vendored). After decode it holds
## PCM and streams it to the kernel via sndPlay — the only path to the hardware.
## Only the final PCM crosses into the kernel; encoded data + decode stay in userspace.

import audio_logic

# ── Kernel ABI (weak stubs patched by the ELF loader at spawn) ─────────────────

proc nimixWrite(buf: pointer; len: int) {.importc, cdecl.}
proc nimixChanRecv(name: cstring; buf: pointer; len: int): int {.importc, cdecl.}
proc nimixChanSend(name: cstring; data: pointer; len: int): int {.importc, cdecl.}
proc nimixSndPlay(pcm: pointer; byteLen: int): int {.importc, cdecl.}

# ── Small helpers ──────────────────────────────────────────────────────────────

proc write(s: cstring) =
  var i = 0
  while s[i] != '\0': inc i
  if i > 0: nimixWrite(cast[pointer](s), i)

# ── Injected sink: stream PCM to the kernel (the hardware path) ────────────────

proc elfPlay(pcm: pointer; byteLen: uint32): int {.nimcall.} =
  ## The single kernel crossing: hand decoded PCM to virtio-snd via sndPlay.
  nimixSndPlay(pcm, int(byteLen))

proc elfStop(): int {.nimcall.} =
  ## Stop is a control-only op today (no dedicated ABI yet); ack it.
  ## ponytail: no-op until virtio-snd STOP is exposed through the ABI.
  0

proc elfVolume(level: uint8): int {.nimcall.} =
  ## Volume is applied during userspace mixing (not yet implemented); ack it.
  ## ponytail: stub — real gain lives in the decode/mix stage.
  0

# ── Request decode ─────────────────────────────────────────────────────────────
# Wire layout of a MediaRequest on the "media" channel (little-endian, packed):
#   [u32 op][u32 pid][u64 base][u32 len][u32 rate][u8 channels][u8 bits][u16 pad]
# Fixed 28 bytes — small enough for the control plane; PCM stays in the region.

const MediaMsgLen = 28

proc decodeRequest(buf: ptr UncheckedArray[uint8]): MediaRequest =
  proc rd32(o: int): uint32 =
    uint32(buf[o]) or (uint32(buf[o+1]) shl 8) or
    (uint32(buf[o+2]) shl 16) or (uint32(buf[o+3]) shl 24)
  proc rd64(o: int): uint64 =
    uint64(rd32(o)) or (uint64(rd32(o+4)) shl 32)
  MediaRequest(
    op:   rd32(0),
    pid:  rd32(4),
    base: rd64(8),
    len:  rd32(16),
    fmt:  MediaFormat(rate: rd32(20), channels: buf[24], bits: buf[25]))

proc encodeReply(r: MediaReply; out: ptr UncheckedArray[uint8]): int =
  ## [i32 err][u32 queued] = 8 bytes.
  let err = cast[uint32](r.err)
  for i in 0..3: out[i]   = uint8((err shr (8*i)) and 0xFF)
  for i in 0..3: out[4+i] = uint8((r.queued shr (8*i)) and 0xFF)
  8

# ── Entry point ────────────────────────────────────────────────────────────────

proc appMain*() {.exportc.} =
  write("audio_server: starting\n")
  let iface = AudioIface(play: elfPlay, stop: elfStop, volume: elfVolume)
  write("audio_server: ready on 'media' channel\n")

  var msgBuf: array[64, uint8]
  var repBuf: array[16, uint8]
  while true:
    let n = nimixChanRecv("media", addr msgBuf[0], msgBuf.len)
    if n >= MediaMsgLen:
      let req = decodeRequest(cast[ptr UncheckedArray[uint8]](addr msgBuf[0]))
      let reply = audioHandle(iface, req)
      let rn = encodeReply(reply, cast[ptr UncheckedArray[uint8]](addr repBuf[0]))
      discard nimixChanSend("media", addr repBuf[0], rn)
