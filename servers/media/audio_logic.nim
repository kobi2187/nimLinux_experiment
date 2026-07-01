# SPDX-License-Identifier: GPL-2.0
## audio_server pure logic — routes media requests to a PCM sink.
##
## Injected interface (AudioIface) so the same logic runs in the ELF server
## (real virtio-snd) and in host tests (recording stub). No kernel ABI imports
## here — this file type-checks and unit-tests on the host.
##
## Design axioms honoured:
##  - Control plane is MsgPack-shaped (MediaRequest: op/pid/base/len/fmt) — tiny.
##  - Data plane is a region the caller granted; we never copy PCM through IPC.
##  - Submission is non-blocking: playFn enqueues and returns immediately, so the
##    server stays responsive under the dispatcher's large-scale concurrency.

type
  MediaOp* = enum
    ## Low byte of the dispatcher op (category 2 = media in the top byte).
    moPlay      = 0x01
    moStop      = 0x02
    moSetVolume = 0x03

  MediaFormat* = object
    ## PCM description carried alongside the region handoff.
    rate*:     uint32     ## sample rate, Hz (e.g. 44100)
    channels*: uint8      ## 1=mono, 2=stereo
    bits*:     uint8      ## bits per sample (16 for S16LE)

  MediaRequest* = object
    ## Request routed from a user app through the dispatcher to audio_server.
    op*:       uint32     ## full dispatcher op; low byte is a MediaOp
    pid*:      uint32     ## caller pid (for QoS accounting / cap checks)
    base*:     uint64     ## region base holding the PCM (0 for non-Play ops)
    len*:      uint32     ## PCM byte length
    fmt*:      MediaFormat

  MediaReply* = object
    err*:      int32      ## 0=ok, negative=error
    queued*:   uint32     ## bytes accepted for playback

  # Injected sink: enqueue one PCM chunk. 0=ok, -1=not ready, -2=ring full.
  PlayFn*   = proc(pcm: pointer; byteLen: uint32): int {.nimcall.}
  # Injected: reclaim completed buffers; return in-flight count (0=idle).
  DrainFn*  = proc(): int {.nimcall.}
  # Injected: cooperative wait (yield) while the ring drains.
  WaitFn*   = proc() {.nimcall.}
  # Injected: stop current stream. Returns 0=ok.
  StopFn*   = proc(): int {.nimcall.}
  # Injected: set volume 0..255. Returns 0=ok.
  VolumeFn* = proc(level: uint8): int {.nimcall.}

  AudioIface* = object
    play*:   PlayFn
    drain*:  DrainFn
    wait*:   WaitFn
    stop*:   StopFn
    volume*: VolumeFn

const
  ChunkBytes* = 4096'u32   ## per-submit PCM chunk (matches virtio-snd periodBytes)
  DrainSpins* = 100_000    ## bound the drain wait so a stuck device can't hang us

# ── Errors ────────────────────────────────────────────────────────────────────

const
  ErrOk*            =  0'i32
  ErrDeviceNotReady* = -1'i32
  ErrBadRequest*     = -2'i32
  ErrUnsupportedOp*  = -3'i32

proc mediaOpOf*(op: uint32): MediaOp {.inline.} =
  ## Extract the media sub-op from the low byte of a dispatcher op.
  MediaOp(op and 0xFF'u32)

# ── Core routing ──────────────────────────────────────────────────────────────

proc streamChunk(iface: AudioIface; base: uint64; off, len: uint32): bool =
  ## Submit one chunk, applying backpressure: if the ring is full (-2), drain and
  ## yield until a slot frees, then retry. Returns false only on device-not-ready.
  let p = cast[pointer](base + off)
  var spins = 0
  while true:
    let rc = iface.play(p, len)
    if rc == ErrOk.int: return true
    if rc != -2: return false          # -1 device not ready
    discard iface.drain()              # ring full → reclaim + wait
    if iface.wait != nil: iface.wait()
    inc spins
    if spins >= DrainSpins: return false

proc audioStream*(iface: AudioIface; req: MediaRequest): MediaReply =
  ## Stream a PCM region to the sink in ChunkBytes pieces with flow control.
  ## Pure: the loop and backpressure policy live here; I/O is injected.
  var off = 0'u32
  while off < req.len:
    let remaining = req.len - off
    let chunk = if remaining < ChunkBytes: remaining else: ChunkBytes
    if not streamChunk(iface, req.base, off, chunk):
      return MediaReply(err: ErrDeviceNotReady, queued: off)
    off += chunk
  MediaReply(err: ErrOk, queued: off)

proc audioHandle*(iface: AudioIface; req: MediaRequest): MediaReply =
  ## Route one media request to the injected sink. Pure — no I/O of its own.
  case mediaOpOf(req.op)
  of moPlay:
    if req.base == 0 or req.len == 0:
      return MediaReply(err: ErrBadRequest)
    # Only S16LE stereo/mono is wired today; reject anything else explicitly so
    # the caller learns rather than hearing silence.
    if req.fmt.bits != 16 or req.fmt.channels notin {1'u8, 2'u8}:
      return MediaReply(err: ErrUnsupportedOp)
    audioStream(iface, req)
  of moStop:
    discard iface.stop()
    MediaReply(err: ErrOk)
  of moSetVolume:
    # Volume level is packed into the len field for the volume op.
    discard iface.volume(uint8(req.len and 0xFF))
    MediaReply(err: ErrOk)
