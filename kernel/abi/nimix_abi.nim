# SPDX-License-Identifier: GPL-2.0
## NimixOS App ABI — the minimal kernel surface exposed to userspace apps.
##
## This is the ONLY interface between a compiled Nim app (--os:standalone)
## and the kernel. Four procs, dispatched through a vtable so the same
## app binary works across kernel models.
##
## The vtable is set during kernel init (same pattern as scheduler/ipc).
## Apps call these via importc from the C ABI header.

type
  NimixAbiVTable* = object
    ## Kernel-side implementations assigned at boot by each model's init.

    # ── Memory ────────────────────────────────────────────────────────────────
    allocRegion*: proc(size: int): pointer {.nimcall.}
    freeRegion*:  proc(p: pointer; size: int) {.nimcall.}

    # ── I/O ───────────────────────────────────────────────────────────────────
    write*: proc(buf: pointer; len: int) {.nimcall.}
    exit*:  proc(code: int) {.nimcall.}

    # ── IPC: named channel (ServerChan) ───────────────────────────────────────
    chanSend*: proc(name: cstring; data: pointer; dataLen: int): int {.nimcall.}
      ## Post `dataLen` bytes to the named channel. Returns 0=ok, -1=not found, -2=full.

    chanRecv*: proc(name: cstring; buf: pointer; bufLen: int): int {.nimcall.}
      ## Dequeue one message from the named channel into buf.
      ## Returns number of bytes written, or -1 if empty / not found.

    # ── IPC: event pub/sub ────────────────────────────────────────────────────
    eventPublish*:   proc(topic: cstring; data: pointer; dataLen: int) {.nimcall.}
      ## Publish an event to all subscribers on topic.

    eventSubscribe*: proc(topic: cstring): uint32 {.nimcall.}
      ## Subscribe to a topic. Returns a token (>0) for polling, 0 on error.

    eventPoll*: proc(token: uint32; buf: pointer; bufLen: int): int {.nimcall.}
      ## Non-blocking poll. Returns bytes written to buf, or -1 if no event.

    # ── Process management ────────────────────────────────────────────────────
    getArgs*:     proc(buf: pointer; len: int): int {.nimcall.}
      ## Copy args string for the current app into buf. Returns bytes written.
    procList*:    proc(buf: pointer; len: int): int {.nimcall.}
      ## Serialize process table as text. Returns bytes written.
    schedStats*:  proc(buf: pointer; len: int): int {.nimcall.}
      ## Serialize scheduler stats as text. Returns bytes written.
    procKillPid*: proc(pid: uint32): int {.nimcall.}
      ## Kill task by PID. Returns 0=ok, -1=not found.
    fsReadDir*:   proc(path: cstring; buf: pointer; len: int): int {.nimcall.}
      ## List directory entries as newline-separated names. Returns bytes written.
    fsRead*: proc(path: cstring; buf: pointer; len: int): int {.nimcall.}
      ## Read entire file into buf. Returns bytes read, or negative on error.
    fsWrite*: proc(path: cstring; buf: pointer; len: int): int {.nimcall.}
      ## Write buf to file at path. Returns 0=ok, negative=error.

    # ── Capability-gated IPC ──────────────────────────────────────────────────
    capSend*: proc(name: cstring; tok: uint64; data: pointer; dataLen: int): int {.nimcall.}
      ## Like chanSend but requires a valid capIpc token. Returns -3 on permission denied.

    # ── Synchronous IPC ───────────────────────────────────────────────────────
    chanCall*: proc(server: cstring; data: pointer; dataLen: int;
                    replyBuf: pointer; replyBufLen: int): int {.nimcall.}
      ## Send to server and spin-wait for reply. Returns reply bytes written, or -1.

    # ── Timing ────────────────────────────────────────────────────────────────
    sleep*: proc(ticks: uint64) {.nimcall.}
      ## Block calling task for `ticks` PIT ticks (100 ticks = 1 second at 100Hz).

    # ── Scheduler ─────────────────────────────────────────────────────────────
    `yield`*: proc() {.nimcall.}
      ## Cooperative yield — hint scheduler to run other ready tasks.

    # ── System info ───────────────────────────────────────────────────────────
    sysInfo*: proc(buf: pointer; len: int): int {.nimcall.}
      ## Serialize system snapshot as YAML into buf. Returns bytes written.

    # -- Capability: memory region ------------------------------------------------
    grantRegion*: proc(slot: int; right: uint32): uint64 {.nimcall.}
      ## Mint a memory capability for the calling task on region `slot`.
      ## `right`: 4=capMemRead, 5=capMemWrite, 6=capMemGrant (CapRight enum values).
      ## Returns the CapToken as uint64, or 0 on failure.

    # ── RTC / wall clock ──────────────────────────────────────────────────────
    uptimeSecs*:  proc(): uint64 {.nimcall.}
      ## Seconds elapsed since kernel boot (from PIT tick counter).
    wallClock*:   proc(buf: pointer; len: int): int {.nimcall.}
      ## Write "YYYY-MM-DD HH:MM:SS\n" into buf. Returns bytes written, -1 if buf too small.

    # ── mmap-style heap growth ────────────────────────────────────────────────
    mapAnon*:     proc(size: int): pointer {.nimcall.}
      ## Allocate `size` bytes from the app's region heap. nil on failure.
    freeAnon*:    proc(p: pointer; size: int) {.nimcall.}
      ## Release memory (no-op for bump allocator; region freed on exit).

    # ── Audio: submit PCM for playback ────────────────────────────────────────
    sndPlay*:     proc(pcm: pointer; byteLen: int): int {.nimcall.}
      ## Enqueue a PCM buffer (S16LE stereo 44100 Hz) on the audio device.
      ## `pcm` points into a region the caller owns; the kernel translates it to a
      ## physical address and hands it to virtio-snd. Non-blocking: returns after
      ## enqueue. Returns 0=ok, -1=device not ready, -2=tx ring full (drain+retry).
      ## Data plane stays zero-copy — no PCM bytes cross an IPC channel.
    sndDrain*:    proc(): int {.nimcall.}
      ## Reclaim completed tx buffers and return the current in-flight count
      ## (buffers submitted but not yet consumed). A streaming caller polls this
      ## to apply backpressure: when sndPlay returns -2, drain then retry.

    # ── IPC: server-owned channels (capability receive) ───────────────────────
    chanCreate*:  proc(name: cstring): uint64 {.nimcall.}
      ## Create a named channel owned by the caller; returns its receive
      ## capability (0 = name taken / no slot). Senders still use chanSend(name).
    capRecv*:     proc(tok: uint64; buf: pointer; bufLen: int): int {.nimcall.}
      ## Receive on the channel bound to `tok`. Bytes, -1 empty, -3 bad token.

    # ── Buffers: bulk data by handle (ipc/buffers, docs/proposals/bulk_data.md)
    # Errors are -ord(BufError). A handle is a per-task value.
    bufCreate*:   proc(size: int): int {.nimcall.}
      ## New owned buffer charged to the caller's budget → handle (> 0).
    bufMap*:      proc(h: uint32): pointer {.nimcall.}
      ## Address of the buffer with the caller's current rights; nil if none.
    bufClose*:    proc(h: uint32): int {.nimcall.}
    bufSeal*:     proc(h: uint32): int {.nimcall.}
      ## owned → sealed: read-only for every holder, forever.
    bufReturn*:   proc(h: uint32): int {.nimcall.}
      ## A borrower ends its lend.
    bufMsgSend*:  proc(name: cstring; data: pointer; dataLen: int; hs: pointer): int {.nimcall.}
      ## Post to a named channel with handles (hs: BufMsgHandles: n, handle[], mode[]).
    bufMsgRecv*:  proc(tok: uint64; buf: pointer; bufLen: int; hs: pointer): int {.nimcall.}
      ## Receive on a channel by receive capability, taking its handles (hs out).
    displayInfo*:    proc(outp: pointer): int {.nimcall.}
      ## Display ABI v1 (docs/proposals/display_abi.md): width, height, format of the scanout.
    displayPresent*: proc(req: pointer): int {.nimcall.}
      ## Show a rectangle of an owned buffer on the display; the first present owns it.

var nimixAbi*: NimixAbiVTable
  ## Global ABI vtable. Set once at boot by the chosen kernel model init.
  ## Apps never call this directly — the ELF loader patches weak stubs with
  ## movabs+jmp trampolines pointing at the vtable fields before calling appMain.
