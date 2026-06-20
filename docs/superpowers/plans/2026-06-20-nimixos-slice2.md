# NimixOS Slice 2 — Hardware Init, Event Server, WASM Runtime

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** From working serial shell → preemptive multitasking OS with pub/sub event system and first WASM application running in a capability-isolated sandbox.

**Architecture:** SASOS model (default). All "processes" are WASM modules running inside SIPs (Software Isolated Processes). The event server is a kernel module (zero-IPC pub/sub). Capabilities are `distinct uint64` tokens — unforgeable by construction.

**Tech Stack:** Nim 2.x, `--mm:arc`, `--os:any`, x86_64, wasm3 (C WASM interpreter, zero deps), QEMU virtio-blk for disk, GRUB Multiboot2, OVMF UEFI.

**Vertical slice goal:** `make qemu` → kernel boots → loads `hello.wasm` from a FAT32 disk image → WASM prints "Hello from NimixOS" to serial → shell shows process list.

---

## Dependency Graph

```
[Slice 1 complete: serial shell boots]
          │
          ▼
┌─────────────────────────────────────────────────────────┐
│  Phase A: Hardware Foundation (all parallel)            │
│   A1: PIC 8259 init + IRQ routing                       │
│   A2: PIT timer (100Hz tick)                            │
│   A3: TSS + syscall gate (ring 0/3)                     │
└─────────────────────────────────────────────────────────┘
          │ (all of A must complete)
          ▼
┌─────────────────────────────────────────────────────────┐
│  Phase B: Kernel Services (parallel after A)            │
│   B1: Preemptive scheduler (needs A2 timer tick)        │
│   B2: Driver registry + probe loop (needs A1 IRQ)       │
│   B3: Event server — pub/sub backbone                   │
└─────────────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────┐
│  Phase C: Storage + WASM (parallel after B)             │
│   C1: PCI bus scan + virtio-blk driver                  │
│   C2: FAT32 VFS reader                                  │
│   C3: wasm3 integration + WASM host ABI                 │
└─────────────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────┐
│  Phase D: First App                                      │
│   D1: SIP loader (load .wasm, assign capabilities)      │
│   D2: hello.wasm — first userspace program              │
│   D3: Shell commands: ps, kill, load <file.wasm>        │
└─────────────────────────────────────────────────────────┘
```

---

## Phase A: Hardware Foundation

### Task A1: PIC 8259 Interrupt Controller

**Files:**
- Create: `drivers/pic.nim`
- Create: `tests/test_pic.nim`
- Modify: `kern/interrupts.nim` (register IRQ handlers via PIC)

**What it does:** Programs the 8259A Programmable Interrupt Controller (master + slave cascade). Remaps IRQs 0–15 from their BIOS defaults (vectors 0x08–0x0F, 0x70–0x77 — which collide with CPU exceptions) to vectors 0x20–0x2F. After this, IRQ1 (keyboard) fires vector 0x21, timer fires 0x20.

- [ ] **Write test (host-compilable — pure port-address constants only)**

```nim
# tests/test_pic.nim
import ../drivers/pic

proc testVectorMapping() =
  assert PicMasterOffset == 0x20, "master IRQs start at vector 0x20"
  assert PicSlaveOffset  == 0x28, "slave IRQs start at vector 0x28"
  assert irqToVector(0)  == 0x20, "IRQ0 (timer) → vector 0x20"
  assert irqToVector(1)  == 0x21, "IRQ1 (keyboard) → vector 0x21"
  assert irqToVector(8)  == 0x28, "IRQ8 (RTC) → vector 0x28"
  echo "PASS: PIC vector mapping"

when isMainModule:
  testVectorMapping()
  echo "All PIC tests passed."
```

- [ ] **Run test to verify it fails:** `nim c -r --skipParentCfg --mm:refc --path:$(pwd) tests/test_pic.nim`

- [ ] **Implement `drivers/pic.nim`**

```nim
# SPDX-License-Identifier: GPL-2.0
## PIC 8259A — Programmable Interrupt Controller
##
## Two cascaded 8259A chips handle IRQs 0-15 on x86.
## BIOS maps them to vectors 0x08-0x0F (collides with CPU exceptions).
## We remap to 0x20-0x2F (safe, above the 32 CPU exception vectors).
##
## After picInit(), IRQ0=timer fires vector 0x20, IRQ1=kbd fires 0x21.

import ../arch/x86_64/cpu_primitives

const
  PicMasterCmd*    = 0x20'u16
  PicMasterData*   = 0x21'u16
  PicSlaveCmd*     = 0xA0'u16
  PicSlaveData*    = 0xA1'u16

  PicMasterOffset* = 0x20'u8   ## IRQ 0-7  → vectors 0x20-0x27
  PicSlaveOffset*  = 0x28'u8   ## IRQ 8-15 → vectors 0x28-0x2F

  PicEoi*          = 0x20'u8   ## End-of-interrupt command

proc irqToVector*(irq: int): uint8 {.inline.} =
  ## Convert IRQ number (0-15) to interrupt vector number.
  if irq < 8: uint8(irq) + PicMasterOffset
  else:       uint8(irq - 8) + PicSlaveOffset

proc ioWait() {.inline.} =
  ## Brief delay after PIC port writes (some hardware needs settling time).
  outb(0x80, 0x00)

proc picInit*() =
  ## Remap PIC IRQs to vectors 0x20-0x2F and mask all interrupts.
  ## Caller must unmask specific IRQs before enabling interrupts.

  # ICW1: start init sequence (cascade mode, ICW4 needed)
  outb(PicMasterCmd,  0x11); ioWait()
  outb(PicSlaveCmd,   0x11); ioWait()

  # ICW2: vector offsets
  outb(PicMasterData, PicMasterOffset); ioWait()
  outb(PicSlaveData,  PicSlaveOffset);  ioWait()

  # ICW3: cascade wiring (master IRQ2 → slave)
  outb(PicMasterData, 0x04); ioWait()  # master: slave on IRQ2
  outb(PicSlaveData,  0x02); ioWait()  # slave: cascade identity = 2

  # ICW4: 8086 mode
  outb(PicMasterData, 0x01); ioWait()
  outb(PicSlaveData,  0x01); ioWait()

  # Mask all IRQs (caller unmasks what it needs)
  outb(PicMasterData, 0xFF)
  outb(PicSlaveData,  0xFF)

proc picEoi*(irq: uint8) {.inline.} =
  ## Send End-Of-Interrupt signal after handling an IRQ.
  ## Must be called at the END of every IRQ handler.
  if irq >= 8:
    outb(PicSlaveCmd, PicEoi)   # cascade: ack slave first
  outb(PicMasterCmd, PicEoi)    # always ack master

proc picUnmask*(irq: uint8) {.inline.} =
  ## Enable (unmask) a specific IRQ line.
  if irq < 8:
    let mask = inb(PicMasterData) and not (1'u8 shl irq)
    outb(PicMasterData, mask)
  else:
    let mask = inb(PicSlaveData) and not (1'u8 shl (irq - 8))
    outb(PicSlaveData, mask)

proc picMask*(irq: uint8) {.inline.} =
  ## Disable (mask) a specific IRQ line.
  if irq < 8:
    let mask = inb(PicMasterData) or (1'u8 shl irq)
    outb(PicMasterData, mask)
  else:
    let mask = inb(PicSlaveData) or (1'u8 shl (irq - 8))
    outb(PicSlaveData, mask)
```

- [ ] **Run test:** all assertions pass
- [ ] **Wire into kernel/init/main.nim:** call `picInit()` early in `runKernel`, before `sti()`
- [ ] **Build kernel:** `make build`
- [ ] **Commit:** `git commit -m "feat: PIC 8259A init — remap IRQs to vectors 0x20-0x2F"`

---

### Task A2: PIT Timer (100Hz tick)

**Files:**
- Create: `drivers/pit.nim`
- Create: `tests/test_pit.nim`
- Modify: `kern/interrupts.nim` (register vector 0x20 handler)
- Modify: `kernel/init/main.nim` (call pitInit, unmask IRQ0)

**What it does:** Programs the Intel 8253/8254 Programmable Interval Timer to fire IRQ0 at 100Hz (10ms tick). This is the scheduler's heartbeat. Every tick, the interrupt handler increments a tick counter and may trigger a context switch.

- [ ] **Write test**

```nim
# tests/test_pit.nim
import ../drivers/pit

proc testDivisorCalc() =
  # PIT base frequency is 1,193,182 Hz
  # At 100 Hz: divisor = 1193182 / 100 = 11931
  let d = pitDivisor(100)
  assert d >= 11931 and d <= 11932, "100Hz divisor should be ~11931"
  let d2 = pitDivisor(1000)
  assert d2 >= 1193 and d2 <= 1194, "1000Hz divisor should be ~1193"
  echo "PASS: PIT divisor calculation"

proc testTickCounter() =
  # Tick counter starts at 0, pitTick() increments it
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
## PIT 8253/8254 — Programmable Interval Timer
##
## Drives the scheduler at a fixed Hz rate.
## IRQ0 (vector 0x20) fires at `pitHz` frequency after pitInit().

import ../arch/x86_64/cpu_primitives
import ../drivers/pic

const
  PitChannel0* = 0x40'u16   ## Channel 0 data port (connected to IRQ0)
  PitCmd*      = 0x43'u16   ## Mode/command register
  PitBaseHz    = 1_193_182  ## PIT oscillator frequency in Hz

var tickCount: uint64 = 0

proc pitTicks*(): uint64 {.inline.} = tickCount

proc pitTick*() {.inline.} =
  ## Called by the IRQ0 handler on each timer interrupt.
  inc tickCount

proc pitDivisor*(hz: int): uint16 =
  ## Calculate the PIT divisor for a given frequency.
  uint16(PitBaseHz div hz)

proc pitInit*(hz: int = 100) =
  ## Program PIT channel 0 to fire at `hz` Hz.
  ## Call picUnmask(0) and sti() after this to start receiving ticks.
  let divisor = pitDivisor(hz)
  # Command: channel 0, lobyte/hibyte access, mode 3 (square wave)
  outb(PitCmd,      0x36)
  outb(PitChannel0, uint8(divisor and 0xFF))         # low byte
  outb(PitChannel0, uint8((divisor shr 8) and 0xFF)) # high byte

proc pitIrqHandler*(vector: uint8) {.nimcall.} =
  ## IRQ0 handler — increments tick counter, signals scheduler.
  pitTick()
  picEoi(0)
  # TODO: call scheduler.preempt() when preemptive scheduling is implemented
```

- [ ] **Run test:** `nim c -r --skipParentCfg --mm:refc --path:$(pwd) tests/test_pit.nim`
- [ ] **Register handler:** in `kern/interrupts.nim`, register `pitIrqHandler` at vector `irqToVector(0)`
- [ ] **Wire into main.nim:** after `picInit()`, call `pitInit(100)` then `picUnmask(0)`
- [ ] **Build kernel:** `make build`
- [ ] **Boot test:** `make qemu` — serial should show tick counter incrementing (add `klogInt(llDebug, "tick=", int64(pitTicks()))` temporarily)
- [ ] **Commit:** `git commit -m "feat: PIT timer at 100Hz — tick counter, IRQ0 handler"`

---

### Task A3: TSS + Syscall Gate

**Files:**
- Create: `arch/x86_64/tss.nim`
- Create: `arch/x86_64/syscall.nim`
- Modify: `arch/x86_64/cpu_primitives.nim` (add `wrmsrl`, `syscall`/`sysret` support)

**What it does:** Sets up the Task State Segment (TSS) so the CPU knows which stack to switch to on ring 3→ring 0 transition. Also configures the `syscall`/`sysret` MSRs so userspace WASM host calls can enter the kernel efficiently.

*(Detailed steps TBD — depends on GDT layout which needs reading first)*

---

## Phase B: Kernel Services

### Task B1: Preemptive Scheduler

**Files:**
- Modify: `kernel/models/monolithic.nim` (add context switch, tick-driven preemption)
- Modify: `drivers/pit.nim` (pitIrqHandler calls scheduler)

**What it does:** On each PIT tick, save the current task's registers (rsp, rbp, rip via the interrupt frame), pick the next ready task, restore its registers. Round-robin with priority.

*(Context switch requires careful inline asm — detailed steps in separate sub-plan)*

---

### Task B2: Driver Registry + Probe Loop

**Files:**
- Create: `kernel/driver_registry.nim`
- Modify: `kernel/init/main.nim`

**What it does:** A static array of `DriverVTable` pointers. At boot, iterate and call `init()` on each. Drivers that detect their hardware return `drOk`; others return `drNotFound` and are skipped. Log results.

- [ ] **Implement `kernel/driver_registry.nim`**

```nim
# SPDX-License-Identifier: GPL-2.0
## Driver Registry — boot-time driver probe loop
##
## Add drivers to the registry in dependency order.
## The probe loop calls init() on each; failures are logged and skipped.

import ./traits/driver
import ../core/log

const MaxDrivers = 32

var
  registry:     array[MaxDrivers, ptr DriverVTable]
  registryCount = 0

proc registerDriver*(d: ptr DriverVTable) =
  if registryCount < MaxDrivers:
    registry[registryCount] = d
    inc registryCount

proc probeAllDrivers*() =
  ## Call init() on every registered driver. Log pass/fail.
  klog(llInfo, "Probing drivers...")
  for i in 0..<registryCount:
    let d = registry[i]
    let r = d.init()
    if r == drOk:
      klog(llInfo, d.name)  # "[INFO]  ps2_keyboard"
    else:
      klog(llWarn, d.name)  # "[WARN]  some_driver (not found)"
```

- [ ] **Wire into main.nim:** after PIC/PIT init, register and probe all drivers
- [ ] **Commit:** `git commit -m "feat: driver registry — probe loop at boot"`

---

### Task B3: Event Server

**Files:**
- Create: `kernel/event_server.nim`
- Create: `kernel/traits/event.nim`
- Create: `tests/test_event_server.nim`

**What it does:** Publish/subscribe backbone for the entire OS. All inter-process coordination goes through here — process exit notifications, device hotplug, timers, app-to-app signalling.

The event server is a **kernel module** (not a separate process), so pub/sub has zero IPC overhead in the SASOS model — it's a direct call into the kernel's event table.

- [ ] **Write failing test**

```nim
# tests/test_event_server.nim
import ../kernel/event_server

proc testSubscribePublish() =
  eventServerInit()

  # Subscribe to a topic
  let token = eventSubscribe("test.ping")
  assert token.isValid, "subscribe should return valid token"

  # Poll — nothing yet
  let before = eventPoll(token)
  assert before.isNone, "nothing published yet"

  # Publish
  eventPublish("test.ping", "hello")

  # Poll — should have event
  let after = eventPoll(token)
  assert after.isSome, "event should be available after publish"
  assert after.get().payload == "hello"
  echo "PASS: subscribe/publish/poll"

proc testWaitAny() =
  eventServerInit()
  let t1 = eventSubscribe("a")
  let t2 = eventSubscribe("b")
  eventPublish("b", "data")
  let fired = eventWaitAny([t1, t2])
  assert fired == t2, "t2 should fire since 'b' was published"
  echo "PASS: waitAny"

when isMainModule:
  testSubscribePublish()
  testWaitAny()
  echo "All event server tests passed."
```

- [ ] **Implement `kernel/traits/event.nim`** (interface only)

```nim
# SPDX-License-Identifier: GPL-2.0
## Event System Trait — Interface
##
## Publish/subscribe event backbone.
## In SASOS: direct kernel call (zero IPC overhead).
## In microkernel: message through event server process.

import ../core/types

const
  MaxTopicLen*    = 64
  MaxPayloadSize* = 512
  MaxSubscribers* = 256

type
  EventToken* = distinct uint32
    ## Opaque subscription handle returned by eventSubscribe().
    ## Pass to eventWait/eventPoll to receive events.

  EventPayload* = object
    size*: uint16
    data*: array[MaxPayloadSize, byte]

  Event* = object
    topic*:   array[MaxTopicLen, char]
    payload*: EventPayload
    seqNum*:  uint64   ## Monotonically increasing — detect missed events

proc isValid*(t: EventToken): bool {.inline.} = uint32(t) != 0
```

- [ ] **Implement `kernel/event_server.nim`**

Core design:
- Topic table: array of `(topic: string, subscribers: seq[EventToken])`
- Each token has a small ring buffer of pending events
- `eventSubscribe(topic)` → allocates a token, registers it under the topic
- `eventPublish(topic, payload)` → fans out to all token buffers for that topic
- `eventPoll(token)` → non-blocking read from token's buffer
- `eventWait(token)` → blocks current task until an event arrives (uses scheduler.blockTask/wake)
- `eventWaitAny(tokens[])` → blocks until any token has an event

- [ ] **Run tests:** `make test`
- [ ] **Wire into main.nim:** call `eventServerInit()` during kernel init
- [ ] **Commit:** `git commit -m "feat: event server — pub/sub backbone for OS coordination"`

---

## Phase C: Storage + WASM

### Task C1: PCI Scan + virtio-blk

**Files:**
- Create: `drivers/pci.nim`
- Create: `drivers/virtio_blk.nim`

**PCI scan:** Walk bus 0 devices 0-31, functions 0-7. Read vendor/device ID from config space (port 0xCF8/0xCFC). Build a device list. QEMU's virtio-blk presents as vendor=0x1AF4, device=0x1001.

**virtio-blk:** Map the virtio device's BAR, set up virtqueues, implement `blkRead(sector, buf)` and `blkWrite(sector, buf)`.

---

### Task C2: FAT32 VFS

**Files:**
- Create: `fs/fat32.nim`
- Create: `fs/vfs.nim`
- Create: `tests/test_fat32.nim`

**FAT32 reader:** Parse BPB (BIOS Parameter Block), read FAT table, follow cluster chains, read directory entries. Implement `fsOpen(path)`, `fsRead(fd, buf, len)`, `fsClose(fd)`.

**VFS layer:** Abstract over the block device. `vfsMount(device, fs)`, `vfsOpen(path)` dispatches to the right filesystem.

Test with a pre-built FAT32 image:
```bash
dd if=/dev/zero of=disk.img bs=512 count=65536
mkfs.fat -F32 disk.img
mount disk.img /mnt && cp hello.wasm /mnt/ && umount /mnt
```

---

### Task C3: wasm3 Integration

**Files:**
- Create: `vendor/wasm3/` (clone or copy wasm3 C source)
- Create: `runtime/wasm_host.nim`
- Create: `runtime/wasm_runner.nim`

**wasm3** is a minimal WASM interpreter in C (~10k lines, zero dependencies). Integrates cleanly into a freestanding kernel via `--passC` and a custom allocator.

**Host ABI** — the WASM module can import these host functions (all capability-gated):

```
env.serial_write(ptr, len)           ← write to serial console
env.event_publish(topic_ptr, payload_ptr, len)
env.event_subscribe(topic_ptr) → token
env.event_wait(token) → filled payload_ptr
env.fs_open(path_ptr) → fd
env.fs_read(fd, buf_ptr, len) → bytes_read
env.fs_close(fd)
env.sip_exit(code)
```

Each import is only available if the loading SIP holds the matching `SipCapability` token.

---

## Phase D: First App

### Task D1: SIP Loader

**Files:**
- Create: `runtime/sip_loader.nim`
- Modify: `kernel/models/sasos.nim`

**What it does:** Load a `.wasm` file from the filesystem, create a SIP with a capability set, instantiate the wasm3 runtime with the allowed host imports, and start execution.

```nim
proc sipLoad*(path: cstring, caps: openArray[SipCapability]): Result[SipId, LoadError]
```

---

### Task D2: hello.wasm

**Files:**
- Create: `apps/hello/hello.wat` (or `hello.c` compiled with wasi-sdk)

```wat
(module
  (import "env" "serial_write" (func $serial_write (param i32 i32)))
  (data (i32.const 0) "Hello from NimixOS WASM!\n")
  (func (export "_start")
    i32.const 0
    i32.const 25
    call $serial_write))
```

Compile: `wat2wasm hello.wat -o hello.wasm`

Add to disk image, load from shell: `load hello.wasm`

---

### Task D3: Shell Commands — ps, load

**Files:**
- Modify: `shell/shell.nim`

Add commands:
- `ps` — list running SIPs (id, name, state)
- `load <file.wasm>` — load and run a WASM module from the filesystem
- `kill <id>` — terminate a SIP by ID

---

## Reference: docs/OS_INIT_GAPS.md

See `docs/OS_INIT_GAPS.md` for the full comparison of what BeOS, QNX, and Linux do at init versus what NimixOS currently has, including the architectural decisions around WASM processes and the event server.
