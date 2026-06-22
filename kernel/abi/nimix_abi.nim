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

    # ── Capability-gated IPC ──────────────────────────────────────────────────
    capSend*: proc(name: cstring; tok: uint64; data: pointer; dataLen: int): int {.nimcall.}
      ## Like chanSend but requires a valid capIpc token. Returns -3 on permission denied.

var nimixAbi*: NimixAbiVTable
  ## Global ABI vtable. Set once at boot by the chosen kernel model init.
  ## Apps never call this directly — the ELF loader patches weak stubs with
  ## movabs+jmp trampolines pointing at the vtable fields before calling appMain.
