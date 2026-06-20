# NimixOS Slice 2 — Hardware Init, Event Server, WASM Runtime

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Reference:** See `docs/ARCHITECTURE.md` for the full three-tier model (Kernel / Servers / WASM Apps) before implementing anything here.

**Goal:** From working serial shell → preemptive multitasking OS with pub/sub event system, a `ping_server` ELF server, and a `pingpong.wasm` app that talks to it — proving the full three-tier IPC stack works end to end.

**Vertical slice goal:**
```
make qemu
→ kernel boots
→ ping_server (ELF) starts, registers mailbox
→ pingpong.wasm loads, sends "ping" to ping_server
→ ping_server replies "pong"
→ pingpong.wasm prints "Got: pong" to serial
→ shell shows: ps (lists both processes)
```

**Architecture:** Three tiers — Kernel (ring 0, Nim), Servers (ring 3, native ELF), Apps (ring 3, WASM). See `docs/ARCHITECTURE.md`.

**Tech Stack:** Nim 2.x, `--mm:arc`, `--os:any`, x86_64, wasm3 (C WASM interpreter), QEMU.

---

## Dependency Graph

```
[Slice 1 complete: serial shell boots ✓]
          │
          ▼
┌─────────────────────────────────────────────────────────┐
│  Phase A: Hardware Foundation (parallel)                │
│   A1: PIC 8259A init + IRQ routing                      │
│   A2: PIT timer 100Hz                                   │
└─────────────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────┐
│  Phase B: Kernel Services (parallel after A)            │
│   B1: Driver registry + probe loop                      │
│   B2: Event server (pub/sub backbone)                   │
│   B3: Syscall gate (ring 0↔3, TSS)                     │
└─────────────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────┐
│  Phase C: IPC + Server Infrastructure (parallel after B)│
│   C1: Server channel (ELF server mailbox API)           │
│   C2: SIP channel (kernel-mediated app→server IPC)      │
│   C3: wasm3 integration + host ABI skeleton             │
└─────────────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────┐
│  Phase D: Proof-of-Concept (sequential)                 │
│   D1: ping_server — tiny ELF server, Nim                │
│   D2: pingpong.wasm — WASM app, sends ping gets pong    │
│   D3: Shell: ps, load <file>                            │
└─────────────────────────────────────────────────────────┘
```

---

## Phase A: Hardware Foundation

### Task A1: PIC 8259A

**Files:** `drivers/pic.nim`, `tests/test_pic.nim`

**Why first:** Without PIC init, IRQ1 (keyboard) and IRQ0 (timer) are either disabled or
mapped to vectors that collide with CPU exceptions. Nothing interactive works.

- [ ] **Write failing test**
```nim
# tests/test_pic.nim
import ../drivers/pic

proc testVectorMapping() =
  assert PicMasterOffset == 0x20'u8
  assert PicSlaveOffset  == 0x28'u8
  assert irqToVector(0)  == 0x20'u8   # timer
  assert irqToVector(1)  == 0x21'u8   # keyboard
  assert irqToVector(8)  == 0x28'u8   # RTC
  assert irqToVector(15) == 0x2F'u8   # last slave IRQ
  echo "PASS: PIC vector mapping"

when isMainModule:
  testVectorMapping()
  echo "All PIC tests passed."
```

- [ ] **Run:** `nim c -r --skipParentCfg --mm:refc --path:$(pwd) tests/test_pic.nim` → expect fail

- [ ] **Implement `drivers/pic.nim`**
```nim
# SPDX-License-Identifier: GPL-2.0
## PIC 8259A — Programmable Interrupt Controller
##
## Remaps IRQ 0-15 from BIOS defaults (collide with CPU exception vectors)
## to safe vectors 0x20-0x2F. Must be called before sti().

import ../arch/x86_64/cpu_primitives

const
  PicMasterCmd*    = 0x20'u16
  PicMasterData*   = 0x21'u16
  PicSlaveCmd*     = 0xA0'u16
  PicSlaveData*    = 0xA1'u16
  PicMasterOffset* = 0x20'u8   ## IRQ 0-7  → vectors 0x20-0x27
  PicSlaveOffset*  = 0x28'u8   ## IRQ 8-15 → vectors 0x28-0x2F
  PicEoi*          = 0x20'u8

proc irqToVector*(irq: int): uint8 {.inline.} =
  if irq < 8: uint8(irq) + PicMasterOffset
  else:       uint8(irq - 8) + PicSlaveOffset

proc ioWait() {.inline.} = outb(0x80, 0x00)

proc picInit*() =
  ## Remap PIC and mask all IRQs. Caller unmasks what it needs.
  outb(PicMasterCmd,  0x11); ioWait()
  outb(PicSlaveCmd,   0x11); ioWait()
  outb(PicMasterData, PicMasterOffset); ioWait()
  outb(PicSlaveData,  PicSlaveOffset);  ioWait()
  outb(PicMasterData, 0x04); ioWait()
  outb(PicSlaveData,  0x02); ioWait()
  outb(PicMasterData, 0x01); ioWait()
  outb(PicSlaveData,  0x01); ioWait()
  outb(PicMasterData, 0xFF)
  outb(PicSlaveData,  0xFF)

proc picEoi*(irq: uint8) {.inline.} =
  if irq >= 8: outb(PicSlaveCmd, PicEoi)
  outb(PicMasterCmd, PicEoi)

proc picUnmask*(irq: uint8) {.inline.} =
  if irq < 8:
    outb(PicMasterData, inb(PicMasterData) and not (1'u8 shl irq))
  else:
    outb(PicSlaveData, inb(PicSlaveData) and not (1'u8 shl (irq - 8)))

proc picMask*(irq: uint8) {.inline.} =
  if irq < 8:
    outb(PicMasterData, inb(PicMasterData) or (1'u8 shl irq))
  else:
    outb(PicSlaveData, inb(PicSlaveData) or (1'u8 shl (irq - 8)))
```

- [ ] **Run test:** all assertions pass
- [ ] **Wire into `kernel/init/main.nim`:** call `picInit()` after IDT setup, before `sti()`
- [ ] **Build:** `make build`
- [ ] **Commit:** `git commit -m "feat: PIC 8259A — remap IRQs to vectors 0x20-0x2F"`

---

### Task A2: PIT Timer 100Hz

**Files:** `drivers/pit.nim`, `tests/test_pit.nim`

- [ ] **Write failing test**
```nim
# tests/test_pit.nim
import ../drivers/pit

proc testDivisorCalc() =
  let d = pitDivisor(100)
  assert d >= 11931 and d <= 11932, "100Hz divisor ~11931"
  let d2 = pitDivisor(1000)
  assert d2 >= 1193 and d2 <= 1194, "1000Hz divisor ~1193"
  echo "PASS: PIT divisor calculation"

proc testTickCounter() =
  resetTicks()
  assert pitTicks() == 0
  pitTick()
  assert pitTicks() == 1
  pitTick()
  assert pitTicks() == 2
  echo "PASS: tick counter"

when isMainModule:
  testDivisorCalc()
  testTickCounter()
  echo "All PIT tests passed."
```

- [ ] **Implement `drivers/pit.nim`**
```nim
# SPDX-License-Identifier: GPL-2.0
## PIT 8253/8254 — drives the scheduler at a fixed Hz rate

import ../arch/x86_64/cpu_primitives
import ../drivers/pic

const
  PitChannel0* = 0x40'u16
  PitCmd*      = 0x43'u16
  PitBaseHz    = 1_193_182

var tickCount: uint64 = 0

proc pitTicks*(): uint64 {.inline.} = tickCount
proc pitTick*()          {.inline.} = inc tickCount
proc resetTicks*()       {.inline.} = tickCount = 0

proc pitDivisor*(hz: int): uint16 =
  uint16(PitBaseHz div hz)

proc pitInit*(hz: int = 100) =
  let d = pitDivisor(hz)
  outb(PitCmd,      0x36)
  outb(PitChannel0, uint8(d and 0xFF))
  outb(PitChannel0, uint8((d shr 8) and 0xFF))

proc pitIrqHandler*(vector: uint8) {.nimcall.} =
  pitTick()
  picEoi(0)
```

- [ ] **Run test:** passes
- [ ] **Register `pitIrqHandler` at vector `irqToVector(0)` in `kern/interrupts.nim`**
- [ ] **Wire into `main.nim`:** after `picInit()`, call `pitInit(100)` then `picUnmask(0)`
- [ ] **Build and boot:** `make qemu` — serial should show kernel running (no hang)
- [ ] **Commit:** `git commit -m "feat: PIT 100Hz timer — tick counter, IRQ0 handler"`

---

## Phase B: Kernel Services

### Task B1: Driver Registry + Probe Loop

**Files:** `kernel/driver_registry.nim`

- [ ] **Implement**
```nim
# SPDX-License-Identifier: GPL-2.0
## Driver Registry — boot-time driver probe loop

import ./traits/driver
import ../core/log

const MaxDrivers = 32

var
  registry:      array[MaxDrivers, ptr DriverVTable]
  registryCount: int = 0

proc registerDriver*(d: ptr DriverVTable) =
  if registryCount < MaxDrivers:
    registry[registryCount] = d
    inc registryCount

proc probeAllDrivers*() =
  klog(llInfo, "Probing drivers...")
  for i in 0..<registryCount:
    let d = registry[i]
    let r = d.init()
    if r == drOk:
      klog(llInfo,  d.name)
    else:
      klog(llWarn, d.name)
```

- [ ] **Wire into `main.nim`:** register `ps2KeyboardDriver`, `vgaTextDriver`, then call `probeAllDrivers()`
- [ ] **Commit:** `git commit -m "feat: driver registry — probe loop at boot"`

---

### Task B2: Event Server

**Files:** `kernel/traits/event.nim`, `kernel/event_server.nim`, `tests/test_event_server.nim`

The event server is the pub/sub backbone. All inter-tier communication flows through it.
In SASOS mode: direct in-kernel call, zero IPC overhead.

- [ ] **Create `kernel/traits/event.nim`**
```nim
# SPDX-License-Identifier: GPL-2.0
## Event System Trait — Interface Only
##
## All tiers (kernel, servers, apps) use this API.
## Implementation: direct call in kernel; syscall from ring 3.

import ../core/types

const
  MaxTopicLen*    = 64
  MaxPayloadLen*  = 512
  MaxSubscribers* = 256
  MaxPendingPerToken* = 16

type
  EventToken* = distinct uint32
    ## Opaque subscription handle. Pass to wait/poll to receive events.

  EventData* = object
    len*:  uint16
    data*: array[MaxPayloadLen, byte]

  Event* = object
    topic*:   array[MaxTopicLen, char]
    payload*: EventData
    seqNum*:  uint64

  EventResult* = enum
    evOk = 0
    evNoToken    ## Token not found or invalid
    evNoEvent    ## Poll found nothing (non-blocking)
    evFull       ## Subscriber ring buffer full — event dropped
    evBadTopic   ## Topic string too long or empty

proc isValid*(t: EventToken): bool {.inline.} = uint32(t) != 0
```

- [ ] **Write failing test `tests/test_event_server.nim`**
```nim
import ../kernel/event_server
import ../kernel/traits/event

proc testSubscribePublishPoll() =
  eventServerInit()

  let tok = eventSubscribe("test.ping")
  assert tok.isValid, "subscribe returns valid token"

  assert eventPoll(tok).isNone, "nothing published yet"

  eventPublish("test.ping", "hello", 5)

  let ev = eventPoll(tok)
  assert ev.isSome, "event available after publish"
  echo "PASS: subscribe/publish/poll"

proc testMultipleSubscribers() =
  eventServerInit()
  let t1 = eventSubscribe("sys.tick")
  let t2 = eventSubscribe("sys.tick")
  eventPublish("sys.tick", "1", 1)
  assert eventPoll(t1).isSome, "t1 receives event"
  assert eventPoll(t2).isSome, "t2 also receives event (fan-out)"
  echo "PASS: fan-out to multiple subscribers"

proc testUnknownTopicReturnsNothing() =
  eventServerInit()
  let tok = eventSubscribe("test.other")
  eventPublish("test.ping", "x", 1)
  assert eventPoll(tok).isNone, "different topic → no event"
  echo "PASS: topic filtering"

when isMainModule:
  testSubscribePublishPoll()
  testMultipleSubscribers()
  testUnknownTopicReturnsNothing()
  echo "All event server tests passed."
```

- [ ] **Implement `kernel/event_server.nim`** (ring buffer per token, topic string matching, fan-out on publish)

- [ ] **Run tests:** `make test`
- [ ] **Wire into `main.nim`:** call `eventServerInit()` during kernel init
- [ ] **Commit:** `git commit -m "feat: event server — pub/sub backbone, fan-out, topic filtering"`

---

### Task B3: Syscall Gate (TSS + ring 0↔3)

**Files:** `arch/x86_64/tss.nim`, `arch/x86_64/syscall_gate.nim`

Sets up the Task State Segment and `syscall`/`sysret` MSRs.
Required before any code (server or WASM host) runs in ring 3.

*(Detailed steps require reading the current GDT layout first — deferred to implementation phase)*

- [ ] **Read current GDT in `arch/x86_64/cpu_primitives.nim`**
- [ ] **Implement TSS with ring 0 stack pointer**
- [ ] **Configure STAR, LSTAR, SFMASK MSRs for `syscall`/`sysret`**
- [ ] **Implement `syscallDispatch` — routes syscall numbers to kernel handlers**
- [ ] **Commit:** `git commit -m "feat: TSS + syscall gate — ring 0/3 transition"`

---

## Phase C: IPC + Server Infrastructure

### Task C1: Server Channel (ELF server mailbox)

**Files:** `ipc/server_chan.nim`, `tests/test_server_chan.nim`

A server registers a named mailbox. Other servers or the kernel post typed messages to it.
Backed by an MPSC (multi-producer, single-consumer) lock-free queue from arsenal.

```nim
# ipc/server_chan.nim
type
  ServerChan*[T] = object
    name*: array[64, char]
    queue: MpscQueue[T]    # from arsenal

proc serverChanCreate*[T](name: cstring): ServerChan[T]
proc serverChanPost*[T](ch: var ServerChan[T], msg: T): bool
proc serverChanRecv*[T](ch: var ServerChan[T]): Option[T]
```

- [ ] **Implement and test**
- [ ] **Register in a global name table** so senders can look up by name
- [ ] **Commit:** `git commit -m "feat: server channel — named MPSC mailbox for ELF servers"`

---

### Task C2: SIP Channel (kernel-mediated app→server IPC)

**Files:** `ipc/sip_chan.nim`

Bridges the WASM host ABI (`env.chan_send`) to the server mailbox system.
The kernel routes the message: WASM app → kernel IPC table → server mailbox.

```nim
proc sipChanSend*(name: cstring, data: ptr byte, len: int, cap: SipCapability): IpcResult
proc sipChanRecv*(name: cstring, buf: ptr byte, maxLen: int): int
```

- [ ] **Implement**
- [ ] **Wire into WASM host ABI (`env.chan_send` / `env.chan_recv`)**
- [ ] **Commit:** `git commit -m "feat: SIP channel — kernel-mediated WASM app to server IPC"`

---

### Task C3: wasm3 Integration

**Files:** `vendor/wasm3/` (C source), `runtime/wasm_host.nim`, `runtime/wasm_runner.nim`

wasm3 is a minimal (~10k line C) WASM interpreter, zero dependencies, works freestanding.

- [ ] **Clone wasm3 into `vendor/wasm3/`**
```bash
git clone https://github.com/wasm3/wasm3 vendor/wasm3 --depth=1
```

- [ ] **Add to Makefile — compile wasm3 C source alongside the kernel:**
```makefile
WASM3_SRC = vendor/wasm3/source
WASM3_OBJS = $(WASM3_SRC)/m3_api_bare.c \
             $(WASM3_SRC)/m3_api_wasi.c \
             $(WASM3_SRC)/m3_core.c \
             $(WASM3_SRC)/m3_env.c \
             $(WASM3_SRC)/m3_exec.c \
             $(WASM3_SRC)/m3_function.c \
             $(WASM3_SRC)/m3_module.c \
             $(WASM3_SRC)/m3_parse.c
```

- [ ] **Create `runtime/wasm_host.nim`** — defines the host ABI functions linked into wasm3:
```nim
# The functions a WASM module can import (capability-gated)
proc hostSerialWrite(runtime: pointer, ctx: pointer): pointer {.exportc, cdecl.}
proc hostChanSend(runtime: pointer, ctx: pointer): pointer {.exportc, cdecl.}
proc hostChanRecv(runtime: pointer, ctx: pointer): pointer {.exportc, cdecl.}
proc hostSipExit(runtime: pointer, ctx: pointer): pointer {.exportc, cdecl.}
```

- [ ] **Create `runtime/wasm_runner.nim`** — loads and runs a `.wasm` file:
```nim
proc wasmRun*(wasmBytes: ptr byte, wasmLen: int,
              caps: openArray[SipCapability]): int
  ## Load and execute a WASM module.
  ## Only binds host functions matching the granted capabilities.
  ## Returns the exit code from env.sip_exit().
```

- [ ] **Test with a trivial WASM module in memory (no filesystem yet):**
```nim
# tests/test_wasm_runner.nim
# Embed a tiny hand-crafted WASM binary that calls serial_write("ok\n")
# and verify it runs without crashing the kernel
```

- [ ] **Commit:** `git commit -m "feat: wasm3 integration — WASM interpreter embedded in kernel"`

---

## Phase D: Proof-of-Concept Ping/Pong

### Task D1: ping_server (ELF server, Nim)

**Files:** `servers/ping_server.nim`

The simplest possible server. Registers a mailbox named `"ping"`.
Reads messages in a loop. If message is `"ping"`, replies `"pong"`.

```nim
# servers/ping_server.nim
# SPDX-License-Identifier: GPL-2.0
## ping_server — proof-of-concept ELF server
##
## Registers mailbox "ping". Receives "ping", replies "pong".
## Proves the kernel → server IPC path works.

import ../ipc/server_chan
import ../core/serial
import ../kernel/event_server

type PingMsg = object
  data: array[16, char]
  replyToken: EventToken

proc main() =
  kprint("ping_server: starting\n")
  var ch = serverChanCreate[PingMsg]("ping")

  # Announce readiness via event server
  eventPublish("server.ready", "ping_server", 11)
  kprint("ping_server: ready\n")

  while true:
    let msg = ch.serverChanRecv()
    if msg.isSome:
      let m = msg.get()
      kprint("ping_server: got ping, sending pong\n")
      # Reply via event token included in the message
      eventPublish("pong", "pong", 4)

main()
```

- [ ] **Add `ping_server` to kernel boot sequence** — kernel spawns it as first ELF server after syscall gate is ready
- [ ] **Commit:** `git commit -m "feat: ping_server — minimal ELF server, mailbox ping/pong"`

---

### Task D2: pingpong.wasm

**Files:** `apps/pingpong/pingpong.wat`

A WASM app that:
1. Subscribes to `"pong"` events
2. Sends `"ping"` to `ping_server` via `env.chan_send`
3. Waits for `"pong"` via `env.event_wait`
4. Writes `"Got: pong\n"` to serial via `env.serial_write`
5. Exits

```wat
(module
  (import "env" "serial_write"   (func $serial_write (param i32 i32)))
  (import "env" "chan_send"      (func $chan_send (param i32 i32 i32 i32)))
  (import "env" "event_subscribe"(func $event_subscribe (param i32) (result i32)))
  (import "env" "event_wait"     (func $event_wait (param i32 i32) (result i32)))

  (memory 1)
  (data (i32.const 0)  "ping")           ;; offset 0, len 4
  (data (i32.const 16) "ping\00")        ;; server name at 16
  (data (i32.const 32) "pong\00")        ;; topic at 32
  (data (i32.const 48) "Got: pong\n")    ;; output at 48, len 10

  (func (export "_start")
    ;; subscribe to "pong" events
    (local $token i32)
    (local.set $token (call $event_subscribe (i32.const 32)))

    ;; send "ping" to "ping" server
    (call $chan_send
      (i32.const 16)   ;; server name ptr
      (i32.const 0)    ;; payload ptr
      (i32.const 4)    ;; payload len
      (i32.const 4))   ;; CAP_IPC = 4

    ;; wait for pong
    (drop (call $event_wait (local.get $token) (i32.const 0)))

    ;; print result
    (call $serial_write (i32.const 48) (i32.const 10))))
```

- [ ] **Compile:** `wat2wasm apps/pingpong/pingpong.wat -o apps/pingpong/pingpong.wasm`
- [ ] **Embed in kernel build** (as a byte array) until FAT32 disk support is ready:
```nim
# runtime/embedded_apps.nim
const PingpongWasm* = staticRead("../../apps/pingpong/pingpong.wasm")
```

- [ ] **Add `load pingpong` to shell** — runs the embedded WASM
- [ ] **Boot test:** `make qemu` → type `load pingpong` → see `Got: pong`
- [ ] **Commit:** `git commit -m "feat: pingpong.wasm — first WASM app, ping/pong with ELF server"`

---

### Task D3: Shell `ps` and `load` commands

**Files:** `shell/shell.nim` (modify)

- [ ] **Add `scPs` and `scLoad` to `ShellCommand` enum**
- [ ] **`ps`** — list running SIPs (id, name, state) from a kernel SIP table
- [ ] **`load <name>`** — look up a named embedded WASM, run it via `wasmRun()`
- [ ] **Commit:** `git commit -m "feat: shell ps + load commands"`

---

## Reference

- Architecture: `docs/ARCHITECTURE.md`
- Boot gap analysis: `docs/OS_INIT_GAPS.md`
- Slice 1 plan (complete): `docs/superpowers/plans/2026-06-20-nimixos-foundation.md`
