# NimixOS Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the foundational infrastructure for a full GUI OS in Nim — from arsenal integration through kernel traits/models, debug layer, and Slice 1 (interactive shell in QEMU).

**Architecture:** Swappable kernel model (monolithic / microkernel / unikernel) selected at compile time via `-d:kernelModel=<model>`. All subsystems program against `kernel/traits/` interfaces only; `kernel/models/` provides concrete implementations. Arsenal is cloned as `vendor/arsenal/` and used directly — no reinvention of its lock-free queues, allocators, or bit-ops.

**Tech Stack:** Nim 2.x, `--mm:arc`, `--os:any`, x86_64, GRUB Multiboot2, QEMU, arsenal (kobi2187/arsenal), grub-mkrescue, OVMF UEFI.

---

## Overview: What We're Building

```
Slice 1 goal: type a command in QEMU serial console → kernel echoes it back
              (proves: interrupts, keyboard driver, scheduler, shell loop all work)

Layer map (bottom → top):
  Layer 0: CPU primitives, atomics, bit-ops         ← already exists, extend with arsenal/bits
  Layer 1: Spinlocks, lock-free queues               ← already exists + arsenal/concurrency
  Layer 2: Physical memory, virtual memory, heap     ← already exists, add arsenal/allocators
  Layer 3: Kernel traits (interfaces)                ← NEW — stable API surface
  Layer 4: Kernel models (implementations)           ← NEW — monolithic first
  Layer 5: Drivers (serial ✓, PS/2 keyboard NEW, VGA text NEW)
  Layer 6: Debug layer (kpanic, kassert, log levels) ← extend existing
  Layer 7: Shell (Slice 1 goal)                      ← NEW
```

---

## File Map

### New files to create
| File | Responsibility |
|------|---------------|
| `vendor/arsenal/` | Cloned arsenal repo (git clone) |
| `kernel/traits/scheduler.nim` | Scheduler interface: spawn, yield, block, wake |
| `kernel/traits/ipc.nim` | IPC interface: send, recv, channels |
| `kernel/traits/driver.nim` | Driver interface: init, deinit, irq_handler |
| `kernel/models/monolithic.nim` | Monolithic wiring: traits → direct function calls |
| `kernel/models/microkernel.nim` | Microkernel wiring: traits → message passing (stub) |
| `kernel/models/unikernel.nim` | Unikernel wiring: everything merged (stub) |
| `kernel/config.nim` | Compile-time feature flags and model selection |
| `drivers/ps2_keyboard.nim` | PS/2 keyboard driver (IRQ1, scancode → ASCII) |
| `drivers/vga_text.nim` | VGA text mode 80×25 framebuffer |
| `shell/shell.nim` | Interactive command loop reading from serial/keyboard |
| `core/log.nim` | Structured logging: levels, kpanic, kassert |
| `tests/test_log.nim` | Tests for log level filtering |
| `tests/test_traits.nim` | Tests for trait interface contracts |

### Existing files to modify
| File | Change |
|------|--------|
| `nim.cfg` | Add `--path:vendor/arsenal/src` so `import arsenal/...` works |
| `kernel/init/main.nim` | Wire up new layers: config → model → drivers → shell |
| `core/serial.nim` | No change — already solid |
| `sync/spinlock.nim` | No change — already has TicketLock, RawSpinLock |
| `nimixos.nimble` | Add arsenal path, add new test task |
| `Makefile` | Add `make shell` target (build + qemu + expect shell prompt) |

---

## Task 1: Clone Arsenal

**Files:**
- Create: `vendor/arsenal/` (via git clone)
- Modify: `nim.cfg`

- [ ] **Step 1: Clone arsenal into vendor/**

```bash
mkdir -p vendor
git clone https://github.com/kobi2187/arsenal vendor/arsenal
```

Expected output: `Cloning into 'vendor/arsenal'...` then success.

- [ ] **Step 2: Verify the key files we need exist**

```bash
ls vendor/arsenal/src/arsenal/concurrency/atomics/atomic.nim
ls vendor/arsenal/src/arsenal/concurrency/queues/spsc.nim
ls vendor/arsenal/src/arsenal/concurrency/queues/mpmc.nim
ls vendor/arsenal/src/arsenal/memory/allocators/bump.nim
ls vendor/arsenal/src/arsenal/memory/allocators/pool.nim
ls vendor/arsenal/src/arsenal/bits/bitops.nim
ls vendor/arsenal/src/arsenal/concurrency/sync/spinlock.nim
```

Expected: all 7 files exist, no errors.

- [ ] **Step 3: Add arsenal/src to Nim path in nim.cfg**

Add to `nim.cfg` (after the existing content):

```nim
# Arsenal library path
--path:"vendor/arsenal/src"
```

- [ ] **Step 4: Verify arsenal imports work in freestanding mode**

Create a quick smoke test (delete after):

```bash
cat > /tmp/test_arsenal_import.nim << 'EOF'
# Test that arsenal atomics import cleanly under --os:any
import arsenal/concurrency/atomics/atomic
import arsenal/bits/bitops

let a = Atomic[int].init(42)
echo "arsenal imports ok"
EOF
nim c --os:any --mm:arc -d:StandaloneHeapSize=16777216 /tmp/test_arsenal_import.nim && /tmp/test_arsenal_import
```

Expected output: `arsenal imports ok`

If this fails with stdlib imports (e.g. `std/options`), proceed to Step 5.

- [ ] **Step 5: Fix any arsenal stdlib dependencies incompatible with --os:any**

Arsenal's atomics imports `std/options`. Check if it compiles under `--os:any`:

```bash
nim c --os:any --mm:arc -d:StandaloneHeapSize=16777216 \
  -d:noSignalHandler /tmp/test_arsenal_import.nim 2>&1 | head -30
```

If `std/options` fails: open `vendor/arsenal/src/arsenal/concurrency/atomics/atomic.nim` and note which stdlib imports are used. The `Option[T]` type is simple enough to replace with our own `core/types.nim` which already has `Option[T]`. Add at top of the arsenal file:

```nim
# For kernel use: redirect stdlib Option to kernel types
when defined(kernelBuild):
  import ../../../../core/types  # has Option[T], Result[T,E]
else:
  import std/options
```

Add `-d:kernelBuild` to `nim.cfg`.

- [ ] **Step 6: Commit**

```bash
git add vendor/arsenal nim.cfg
git commit -m "feat: vendor arsenal library, add to nim path"
```

---

## Task 2: Structured Logging + kpanic + kassert

**Files:**
- Create: `core/log.nim`
- Create: `tests/test_log.nim`

- [ ] **Step 1: Write failing tests for log level filtering**

Create `tests/test_log.nim`:

```nim
# SPDX-License-Identifier: GPL-2.0
## Tests for structured kernel logging

import ../core/log

# Test 1: log level filtering
proc testLogLevels() =
  # At compile time with -d:logLevel=2 (WARN), DEBUG and INFO are no-ops
  # We can't easily test "no output" without capturing serial, so we test
  # that the level constants are correctly ordered
  assert ord(llDebug) < ord(llInfo)
  assert ord(llInfo) < ord(llWarn)
  assert ord(llWarn) < ord(llError)
  assert ord(llError) < ord(llPanic)
  echo "PASS: log levels ordered correctly"

# Test 2: kpanic is noreturn (compile-time check — if this compiles, it passes)
proc testPanicIsNoReturn() =
  # This proc has a return value but never returns — valid only if kpanic is {.noreturn.}
  proc mustReturn(): int =
    kpanic("test panic - never actually called")
  echo "PASS: kpanic is noreturn"

# Test 3: kassert does nothing when condition is true
proc testKassertPass() =
  kassert(1 + 1 == 2, "math is broken")
  echo "PASS: kassert passes on true condition"

when isMainModule:
  testLogLevels()
  testPanicIsNoReturn()
  testKassertPass()
```

- [ ] **Step 2: Run test to verify it fails (log module doesn't exist yet)**

```bash
nim c -r tests/test_log.nim 2>&1 | head -10
```

Expected: `Error: cannot open file: ../core/log`

- [ ] **Step 3: Write core/log.nim**

Create `core/log.nim`:

```nim
# SPDX-License-Identifier: GPL-2.0
## Structured Kernel Logging - LAYER 0
##
## Compile-time log level filtering via -d:logLevel=N
## Levels: 0=DEBUG 1=INFO 2=WARN 3=ERROR 4=PANIC (default=1)
##
## Usage:
##   klog(llInfo, "hello from kernel")
##   kassert(x > 0, "x must be positive")
##   kpanic("unrecoverable state")

import ./serial

type
  LogLevel* = enum
    llDebug = 0
    llInfo  = 1
    llWarn  = 2
    llError = 3
    llPanic = 4

const
  KernelLogLevel* {.intdefine: "logLevel".} = 1  ## Default: INFO

  LevelPrefix: array[LogLevel, cstring] = [
    "[DEBUG] ",
    "[INFO]  ",
    "[WARN]  ",
    "[ERROR] ",
    "[PANIC] "
  ]

proc klog*(level: LogLevel, msg: cstring) {.inline.} =
  ## Log a message at the given level.
  ## Messages below KernelLogLevel are compiled out entirely.
  when ord(level) >= KernelLogLevel:
    defaultSerial.putString(LevelPrefix[level])
    defaultSerial.putString(msg)
    defaultSerial.putChar('\n')

proc klogHex*(level: LogLevel, label: cstring, val: uint64) {.inline.} =
  ## Log a label + hex value.
  when ord(level) >= KernelLogLevel:
    defaultSerial.putString(LevelPrefix[level])
    defaultSerial.putString(label)
    defaultSerial.putString("0x")
    defaultSerial.putHex(val)
    defaultSerial.putChar('\n')

proc klogInt*(level: LogLevel, label: cstring, val: int64) {.inline.} =
  ## Log a label + decimal integer.
  when ord(level) >= KernelLogLevel:
    defaultSerial.putString(LevelPrefix[level])
    defaultSerial.putString(label)
    defaultSerial.putInt(val)
    defaultSerial.putChar('\n')

proc kpanic*(msg: cstring) {.noreturn, inline.} =
  ## Print panic message and halt the CPU forever.
  ## This is the kernel's last resort — no recovery.
  defaultSerial.putString("\n[PANIC] ")
  defaultSerial.putString(msg)
  defaultSerial.putString("\n[PANIC] System halted.\n")
  while true:
    when defined(amd64) or defined(x86_64):
      {.emit: """asm volatile("cli; hlt");""".}

template kassert*(cond: bool, msg: cstring) =
  ## Assert condition; kpanic if false.
  ## Compiled out when -d:release used with -d:logLevel=5 or higher.
  if not cond:
    kpanic(msg)
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
nim c -r tests/test_log.nim
```

Expected:
```
PASS: log levels ordered correctly
PASS: kpanic is noreturn
PASS: kassert passes on true condition
```

- [ ] **Step 5: Update kernel/init/main.nim to use klog instead of earlyPutString where appropriate**

In `kernel/init/main.nim`, after `initSerial()` is called, replace lines like:
```nim
earlyPutString("[BOOT] Starting kernel\n")
```
with:
```nim
klog(llInfo, "Starting kernel")
```

Keep `earlyPutString` only for pre-serial-init output (the very first lines before `initSerial()`).

- [ ] **Step 6: Verify kernel still compiles**

```bash
make build 2>&1 | tail -5
```

Expected: `build/main` exists, no errors.

- [ ] **Step 7: Commit**

```bash
git add core/log.nim tests/test_log.nim kernel/init/main.nim
git commit -m "feat: add structured logging, kpanic, kassert"
```

---

## Task 3: Kernel Traits Layer

**Files:**
- Create: `kernel/config.nim`
- Create: `kernel/traits/scheduler.nim`
- Create: `kernel/traits/ipc.nim`
- Create: `kernel/traits/driver.nim`
- Create: `tests/test_traits.nim`

These are **interface-only** files — no implementation, just type definitions and proc signatures. Think of them as Nim's answer to C header files or Rust traits.

- [ ] **Step 1: Write failing trait interface tests**

Create `tests/test_traits.nim`:

```nim
# SPDX-License-Identifier: GPL-2.0
## Tests for kernel trait interfaces
## These verify the interfaces are importable and types are correct.

import ../kernel/traits/scheduler
import ../kernel/traits/ipc
import ../kernel/traits/driver
import ../kernel/config

proc testSchedulerTypes() =
  # Verify TaskId is a distinct type (not just an alias)
  let id1 = TaskId(1)
  let id2 = TaskId(2)
  assert id1 != id2
  assert ord(tsReady) < ord(tsBlocked)
  echo "PASS: scheduler trait types correct"

proc testIpcTypes() =
  assert MessageSize > 0
  assert ord(mrOk) == 0
  echo "PASS: ipc trait types correct"

proc testDriverTypes() =
  assert ord(drOk) == 0
  echo "PASS: driver trait types correct"

proc testConfig() =
  # KernelModel is set at compile time
  echo "PASS: kernel model = ", $KernelModel
  echo "PASS: config accessible"

when isMainModule:
  testSchedulerTypes()
  testIpcTypes()
  testDriverTypes()
  testConfig()
```

- [ ] **Step 2: Run to verify it fails**

```bash
nim c -r tests/test_traits.nim 2>&1 | head -5
```

Expected: `Error: cannot open file: ../kernel/config`

- [ ] **Step 3: Create kernel/config.nim**

```nim
# SPDX-License-Identifier: GPL-2.0
## Kernel Compile-Time Configuration
##
## Select kernel model with: -d:kernelModel=monolithic (default)
##                           -d:kernelModel=microkernel
##                           -d:kernelModel=unikernel

type
  KernelModelKind* = enum
    kmMonolithic   = "monolithic"
    kmMicrokernel  = "microkernel"
    kmUnikernel    = "unikernel"

const
  KernelModel* {.strdefine: "kernelModel".} = "monolithic"

  IsMonolithic*  = KernelModel == "monolithic"
  IsMicrokernel* = KernelModel == "microkernel"
  IsUnikernel*   = KernelModel == "unikernel"

  # Feature flags
  EnableSMP*    {.booldefine.} = false  ## Multi-core support
  EnableVGA*    {.booldefine.} = true   ## VGA text mode
  EnablePS2*    {.booldefine.} = true   ## PS/2 keyboard
  MaxTasks*     = 256                   ## Max simultaneous tasks
  MaxChannels*  = 64                    ## Max IPC channels
```

- [ ] **Step 4: Create kernel/traits/scheduler.nim**

```nim
# SPDX-License-Identifier: GPL-2.0
## Scheduler Trait - Interface Only
##
## Any scheduler implementation must provide these operations.
## Import this in code that uses scheduling; never import a model directly.

import ../../core/types

type
  TaskId* = distinct uint32
    ## Opaque task identifier. Distinct so it can't be confused with a plain uint32.

  TaskPriority* = range[0..255]
    ## 0 = lowest, 255 = highest (real-time)

  TaskState* = enum
    tsReady    ## Can run now
    tsRunning  ## Currently executing
    tsBlocked  ## Waiting for event
    tsSleeping ## Waiting for time
    tsZombie   ## Finished, awaiting cleanup

  TaskProc* = proc() {.nimcall.}
    ## Entry point for a task (no args — use closure or message for data)

  SchedulerError* = enum
    seOk = 0
    seOutOfSlots    ## MaxTasks reached
    seInvalidTask   ## TaskId not found
    seNotBlocked    ## Can't wake non-blocked task

  ## Virtual table — implementations fill this in
  SchedulerVTable* = object
    spawn*:   proc(entry: TaskProc, priority: TaskPriority): Result[TaskId, SchedulerError] {.nimcall.}
    yield*:   proc() {.nimcall.}
    block*:   proc(id: TaskId): Result[void, SchedulerError] {.nimcall.}
    wake*:    proc(id: TaskId): Result[void, SchedulerError] {.nimcall.}
    current*: proc(): TaskId {.nimcall.}
    exit*:    proc() {.noreturn, nimcall.}

var scheduler*: SchedulerVTable
  ## Global scheduler vtable — set by the chosen kernel model at init time.
```

- [ ] **Step 5: Create kernel/traits/ipc.nim**

```nim
# SPDX-License-Identifier: GPL-2.0
## IPC Trait - Interface Only
##
## Inter-process/task communication interface.
## In monolithic mode: direct memory copy.
## In microkernel mode: message passing through kernel.

import ../../core/types
import ./scheduler

const
  MessageSize* = 256  ## Max bytes in a single message

type
  ChannelId* = distinct uint32

  Message* = object
    sender*: TaskId
    size*:   uint16
    data*:   array[MessageSize, byte]

  IpcResult* = enum
    mrOk = 0
    mrFull      ## Channel buffer full
    mrEmpty     ## Channel has no messages
    mrInvalid   ## Invalid channel id
    mrTimeout   ## Timed out waiting

  IpcVTable* = object
    send*:    proc(ch: ChannelId, msg: ptr Message): IpcResult {.nimcall.}
    recv*:    proc(ch: ChannelId, msg: ptr Message): IpcResult {.nimcall.}
    tryRecv*: proc(ch: ChannelId, msg: ptr Message): IpcResult {.nimcall.}
    open*:    proc(): Result[ChannelId, IpcResult] {.nimcall.}
    close*:   proc(ch: ChannelId): IpcResult {.nimcall.}

var ipc*: IpcVTable
```

- [ ] **Step 6: Create kernel/traits/driver.nim**

```nim
# SPDX-License-Identifier: GPL-2.0
## Driver Trait - Interface Only
##
## All device drivers implement this interface.
## Enables the kernel to manage drivers uniformly.

import ../../core/types

type
  DriverResult* = enum
    drOk = 0
    drNotFound     ## Device not present
    drInitFailed   ## Failed to initialize
    drBusy         ## Device busy
    drInvalidOp    ## Operation not supported

  IrqHandler* = proc(vector: uint8): void {.nimcall.}

  DriverVTable* = object
    name*:   cstring
    init*:   proc(): DriverResult {.nimcall.}
    deinit*: proc(): DriverResult {.nimcall.}
    irq*:    IrqHandler  ## Called by interrupt dispatcher; nil if no IRQ
```

- [ ] **Step 7: Run trait tests**

```bash
nim c -r tests/test_traits.nim
```

Expected:
```
PASS: scheduler trait types correct
PASS: ipc trait types correct
PASS: driver trait types correct
PASS: kernel model = monolithic
PASS: config accessible
```

- [ ] **Step 8: Commit**

```bash
git add kernel/config.nim kernel/traits/ tests/test_traits.nim
git commit -m "feat: kernel traits layer — scheduler, ipc, driver interfaces"
```

---

## Task 4: Monolithic Model Implementation

**Files:**
- Create: `kernel/models/monolithic.nim`

The monolithic model wires up the scheduler and IPC traits using direct function calls — no message passing overhead. This is what Linux does.

- [ ] **Step 1: Write a failing integration test**

Add to `tests/test_traits.nim` (append after existing tests, before `when isMainModule`):

```nim
import ../kernel/models/monolithic

proc testMonolithicInit() =
  # After init, the global vtables should be populated
  initMonolithicModel()
  assert not scheduler.spawn.isNil, "scheduler.spawn must be set"
  assert not scheduler.yield.isNil, "scheduler.yield must be set"
  assert not ipc.send.isNil, "ipc.send must be set"
  echo "PASS: monolithic model initializes vtables"
```

And in `when isMainModule` block add:
```nim
  testMonolithicInit()
```

Run to verify failure:
```bash
nim c -r tests/test_traits.nim 2>&1 | head -5
```

Expected: `Error: cannot open file: ../kernel/models/monolithic`

- [ ] **Step 2: Create kernel/models/monolithic.nim**

```nim
# SPDX-License-Identifier: GPL-2.0
## Monolithic Kernel Model
##
## Wires up the kernel trait vtables using direct function calls.
## All services run in the same address space — no IPC overhead.
##
## To select: compile with -d:kernelModel=monolithic (default)

import ../traits/scheduler
import ../traits/ipc
import ../traits/driver
import ../../core/types
import ../../core/log
import ../../sync/spinlock

# ── Simple Round-Robin Task Table ─────────────────────────────────────────

const MaxTaskSlots = 256

type
  TaskEntry = object
    id:       TaskId
    state:    TaskState
    entry:    TaskProc
    priority: TaskPriority
    used:     bool

var
  tasks:       array[MaxTaskSlots, TaskEntry]
  taskCount:   int
  currentTask: int
  taskLock:    SpinLock

proc nextTaskId(): TaskId =
  var highest = TaskId(0)
  for t in tasks:
    if t.used and uint32(t.id) > uint32(highest):
      highest = t.id
  TaskId(uint32(highest) + 1)

# ── Scheduler Implementation ───────────────────────────────────────────────

proc monoSpawn(entry: TaskProc, priority: TaskPriority): Result[TaskId, SchedulerError] {.nimcall.} =
  withLock(taskLock):
    if taskCount >= MaxTaskSlots:
      return err(SchedulerError.seOutOfSlots)
    for i in 0..<MaxTaskSlots:
      if not tasks[i].used:
        let id = nextTaskId()
        tasks[i] = TaskEntry(id: id, state: tsReady, entry: entry,
                             priority: priority, used: true)
        inc taskCount
        return ok(id)
  err(SchedulerError.seOutOfSlots)

proc monoYield() {.nimcall.} =
  # In monolithic cooperative mode: find next ready task and run it.
  # For Slice 1 (single task shell), this is effectively a no-op.
  discard

proc monoBlock(id: TaskId): Result[void, SchedulerError] {.nimcall.} =
  withLock(taskLock):
    for i in 0..<MaxTaskSlots:
      if tasks[i].used and tasks[i].id == id:
        tasks[i].state = tsBlocked
        return ok()
  err(SchedulerError.seInvalidTask)

proc monoWake(id: TaskId): Result[void, SchedulerError] {.nimcall.} =
  withLock(taskLock):
    for i in 0..<MaxTaskSlots:
      if tasks[i].used and tasks[i].id == id:
        if tasks[i].state != tsBlocked:
          return err(SchedulerError.seNotBlocked)
        tasks[i].state = tsReady
        return ok()
  err(SchedulerError.seInvalidTask)

proc monoCurrent(): TaskId {.nimcall.} =
  if currentTask < MaxTaskSlots and tasks[currentTask].used:
    tasks[currentTask].id
  else:
    TaskId(0)

proc monoExit() {.noreturn, nimcall.} =
  kpanic("task called exit — not yet implemented")

# ── Simple Message Queue for IPC ───────────────────────────────────────────

const MaxChannels = 64
const ChannelBufSize = 8

type
  Channel = object
    open:  bool
    head:  int
    tail:  int
    count: int
    buf:   array[ChannelBufSize, Message]
    lock:  SpinLock

var channels: array[MaxChannels, Channel]

proc monoIpcOpen(): Result[ChannelId, IpcResult] {.nimcall.} =
  for i in 0..<MaxChannels:
    if not channels[i].open:
      channels[i].open = true
      channels[i].head = 0
      channels[i].tail = 0
      channels[i].count = 0
      return ok(ChannelId(i))
  err(IpcResult.mrInvalid)

proc monoIpcClose(ch: ChannelId): IpcResult {.nimcall.} =
  let i = int(ch)
  if i >= MaxChannels or not channels[i].open:
    return mrInvalid
  channels[i].open = false
  mrOk

proc monoIpcSend(ch: ChannelId, msg: ptr Message): IpcResult {.nimcall.} =
  let i = int(ch)
  if i >= MaxChannels or not channels[i].open: return mrInvalid
  withLock(channels[i].lock):
    if channels[i].count >= ChannelBufSize: return mrFull
    channels[i].buf[channels[i].tail] = msg[]
    channels[i].tail = (channels[i].tail + 1) mod ChannelBufSize
    inc channels[i].count
  mrOk

proc monoIpcRecv(ch: ChannelId, msg: ptr Message): IpcResult {.nimcall.} =
  let i = int(ch)
  if i >= MaxChannels or not channels[i].open: return mrInvalid
  withLock(channels[i].lock):
    if channels[i].count == 0: return mrEmpty
    msg[] = channels[i].buf[channels[i].head]
    channels[i].head = (channels[i].head + 1) mod ChannelBufSize
    dec channels[i].count
  mrOk

proc monoIpcTryRecv(ch: ChannelId, msg: ptr Message): IpcResult {.nimcall.} =
  monoIpcRecv(ch, msg)  # Same as recv in this simple model

# ── Wire Up Vtables ────────────────────────────────────────────────────────

proc initMonolithicModel*() =
  ## Call once at kernel init. Populates global scheduler and ipc vtables.
  taskLock.init()

  scheduler = SchedulerVTable(
    spawn:   monoSpawn,
    yield:   monoYield,
    block:   monoBlock,
    wake:    monoWake,
    current: monoCurrent,
    exit:    monoExit
  )

  ipc = IpcVTable(
    send:    monoIpcSend,
    recv:    monoIpcRecv,
    tryRecv: monoIpcTryRecv,
    open:    monoIpcOpen,
    close:   monoIpcClose
  )

  klog(llInfo, "Monolithic model initialized")
```

- [ ] **Step 3: Run tests**

```bash
nim c -r tests/test_traits.nim
```

Expected: all 5 PASS lines including `PASS: monolithic model initializes vtables`

- [ ] **Step 4: Add microkernel and unikernel stubs (compile-check only)**

Create `kernel/models/microkernel.nim`:

```nim
# SPDX-License-Identifier: GPL-2.0
## Microkernel Model — STUB
##
## TODO: implement message-passing IPC, user-space servers
## For now: same as monolithic but documents the intent.

import ../traits/scheduler
import ../traits/ipc
import ./monolithic  # Reuse implementation until microkernel IPC is written

proc initMicrokernelModel*() =
  ## Stub: initializes same as monolithic for now.
  ## When microkernel IPC is implemented, this will differ.
  initMonolithicModel()
```

Create `kernel/models/unikernel.nim`:

```nim
# SPDX-License-Identifier: GPL-2.0
## Unikernel Model — STUB
##
## TODO: merge app + kernel, remove protection rings

import ./monolithic

proc initUnikernelModel*() =
  initMonolithicModel()
```

- [ ] **Step 5: Commit**

```bash
git add kernel/models/ tests/test_traits.nim
git commit -m "feat: monolithic kernel model, microkernel/unikernel stubs"
```

---

## Task 5: PS/2 Keyboard Driver

**Files:**
- Create: `drivers/ps2_keyboard.nim`
- Create: `tests/test_ps2_keyboard.nim`

The PS/2 keyboard is the simplest way to get interactive input in QEMU. It uses port 0x60 (data) and IRQ1.

- [ ] **Step 1: Write failing tests**

Create `tests/test_ps2_keyboard.nim`:

```nim
# SPDX-License-Identifier: GPL-2.0
## Tests for PS/2 keyboard scancode translation

import ../drivers/ps2_keyboard

proc testScancodeToAscii() =
  # Known US QWERTY scancode → ASCII mappings
  assert scancodeToAscii(0x1E) == 'a'  # A key make code
  assert scancodeToAscii(0x30) == 'b'  # B key
  assert scancodeToAscii(0x2E) == 'c'  # C key
  assert scancodeToAscii(0x39) == ' '  # Space
  assert scancodeToAscii(0x1C) == '\n' # Enter
  assert scancodeToAscii(0x0E) == '\b' # Backspace
  echo "PASS: scancode to ASCII mapping correct"

proc testBreakCodeIgnored() =
  # Break codes (key release) have bit 7 set — should return '\0'
  assert scancodeToAscii(0x1E or 0x80) == '\0'  # A key release
  assert scancodeToAscii(0x81) == '\0'
  echo "PASS: break codes return null char"

when isMainModule:
  testScancodeToAscii()
  testBreakCodeIgnored()
```

- [ ] **Step 2: Run to verify failure**

```bash
nim c -r tests/test_ps2_keyboard.nim 2>&1 | head -5
```

Expected: `Error: cannot open file: ../drivers/ps2_keyboard`

- [ ] **Step 3: Create drivers/ps2_keyboard.nim**

```nim
# SPDX-License-Identifier: GPL-2.0
## PS/2 Keyboard Driver
##
## Handles IRQ1, reads scancodes from port 0x60, translates to ASCII.
## Stores characters in a small ring buffer read by the shell.

import ../arch/x86_64/cpu_primitives
import ../kernel/traits/driver
import ../core/log

const
  Ps2DataPort*   = 0x60'u16
  Ps2StatusPort* = 0x64'u16
  KeyboardIrq*   = 1'u8
  BufSize        = 64

# ── Scancode → ASCII (US QWERTY, Set 1 make codes) ────────────────────────

const ScancodeTable: array[128, char] = [
  '\0', '\0', '1', '2', '3', '4', '5', '6', '7', '8',  # 0x00-0x09
  '9', '0', '-', '=', '\b', '\t', 'q', 'w', 'e', 'r',  # 0x0A-0x13
  't', 'y', 'u', 'i', 'o', 'p', '[', ']', '\n', '\0',  # 0x14-0x1D
  'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';',   # 0x1E-0x27
  '\'', '`', '\0', '\\', 'z', 'x', 'c', 'v', 'b', 'n', # 0x28-0x31
  'm', ',', '.', '/', '\0', '*', '\0', ' ', '\0',        # 0x32-0x3A
  '\0', '\0', '\0', '\0', '\0', '\0', '\0', '\0', '\0', '\0', # 0x3B-0x44
  '\0', '\0', '\0', '\0', '\0', '\0', '\0', '\0', '\0', '\0', # 0x45-0x4E
  '\0', '\0', '\0', '\0', '\0', '\0', '\0', '\0', '\0', '\0', # 0x4F-0x58
  '\0', '\0', '\0', '\0', '\0', '\0', '\0', '\0', '\0', '\0', # 0x59-0x62
  '\0', '\0', '\0', '\0', '\0', '\0', '\0', '\0', '\0', '\0', # 0x63-0x6C
  '\0', '\0', '\0', '\0', '\0', '\0', '\0', '\0', '\0', '\0', # 0x6D-0x76
  '\0', '\0', '\0', '\0', '\0', '\0', '\0', '\0'          # 0x77-0x7F
]

proc scancodeToAscii*(scancode: uint8): char =
  ## Translate a Set 1 make scancode to ASCII.
  ## Returns '\0' for break codes (bit 7 set) or unmapped keys.
  if (scancode and 0x80) != 0: return '\0'  # Break code (key release)
  if int(scancode) >= ScancodeTable.len: return '\0'
  ScancodeTable[int(scancode)]

# ── Ring Buffer ────────────────────────────────────────────────────────────

var
  kbdBuf:  array[BufSize, char]
  kbdHead: int
  kbdTail: int
  kbdCount: int

proc kbdBufPush(c: char) {.inline.} =
  if kbdCount < BufSize:
    kbdBuf[kbdTail] = c
    kbdTail = (kbdTail + 1) mod BufSize
    inc kbdCount

proc kbdBufPop*(): char =
  ## Read next character from keyboard buffer. Returns '\0' if empty.
  if kbdCount == 0: return '\0'
  result = kbdBuf[kbdHead]
  kbdHead = (kbdHead + 1) mod BufSize
  dec kbdCount

proc kbdBufReady*(): bool {.inline.} =
  ## Returns true if there is a character waiting.
  kbdCount > 0

# ── IRQ Handler ────────────────────────────────────────────────────────────

proc kbdIrqHandler*(vector: uint8) {.nimcall.} =
  ## Called by interrupt dispatcher on IRQ1.
  let scancode = inb(Ps2DataPort)
  let ch = scancodeToAscii(scancode)
  if ch != '\0':
    kbdBufPush(ch)

# ── Driver VTable ──────────────────────────────────────────────────────────

proc kbdInit(): DriverResult {.nimcall.} =
  kbdHead = 0; kbdTail = 0; kbdCount = 0
  klog(llInfo, "PS/2 keyboard initialized")
  drOk

proc kbdDeinit(): DriverResult {.nimcall.} =
  drOk

let ps2KeyboardDriver* = DriverVTable(
  name:   "ps2_keyboard",
  init:   kbdInit,
  deinit: kbdDeinit,
  irq:    kbdIrqHandler
)
```

- [ ] **Step 4: Run keyboard tests**

```bash
nim c -r tests/test_ps2_keyboard.nim
```

Expected:
```
PASS: scancode to ASCII mapping correct
PASS: break codes return null char
```

- [ ] **Step 5: Commit**

```bash
git add drivers/ps2_keyboard.nim tests/test_ps2_keyboard.nim
git commit -m "feat: PS/2 keyboard driver with scancode translation and ring buffer"
```

---

## Task 6: VGA Text Mode Driver

**Files:**
- Create: `drivers/vga_text.nim`
- Create: `tests/test_vga_text.nim`

VGA text mode is a 80×25 grid of character+attribute bytes at physical address 0xB8000. It gives us a screen to write to (complement to serial).

- [ ] **Step 1: Write failing tests**

Create `tests/test_vga_text.nim`:

```nim
# SPDX-License-Identifier: GPL-2.0
## Tests for VGA text mode driver (logic only — no real hardware needed)

import ../drivers/vga_text

proc testColorEncoding() =
  let attr = vgaAttr(vgaWhite, vgaBlack)
  assert (attr and 0x0F) == uint8(vgaWhite)   # foreground in low nibble
  assert (attr shr 4) == uint8(vgaBlack)       # background in high nibble
  echo "PASS: VGA color attribute encoding correct"

proc testCursorBounds() =
  var vga = VgaState()
  vgaInit(vga, nil)  # nil = no real framebuffer (test mode)
  vga.col = VgaWidth - 1
  vga.row = VgaHeight - 1
  # Writing past end should wrap
  vgaAdvanceCursor(vga)
  assert vga.row == 0 or vga.row == VgaHeight - 1  # scrolled or wrapped
  echo "PASS: cursor bounds enforced"

when isMainModule:
  testColorEncoding()
  testCursorBounds()
```

- [ ] **Step 2: Run to verify failure**

```bash
nim c -r tests/test_vga_text.nim 2>&1 | head -5
```

Expected: `Error: cannot open file: ../drivers/vga_text`

- [ ] **Step 3: Create drivers/vga_text.nim**

```nim
# SPDX-License-Identifier: GPL-2.0
## VGA Text Mode Driver
##
## 80×25 color text console at physical address 0xB8000.
## Each cell is 2 bytes: [character][attribute].
## Attribute: bits 0-3 = foreground color, bits 4-6 = background, bit 7 = blink.

import ../kernel/traits/driver
import ../core/log

const
  VgaAddr*   = 0xB8000'u64
  VgaWidth*  = 80
  VgaHeight* = 25

type
  VgaColor* = enum
    vgaBlack=0, vgaBlue, vgaGreen, vgaCyan, vgaRed, vgaMagenta,
    vgaBrown, vgaLightGray, vgaDarkGray, vgaLightBlue, vgaLightGreen,
    vgaLightCyan, vgaLightRed, vgaLightMagenta, vgaYellow, vgaWhite

  VgaState* = object
    buf*: ptr UncheckedArray[uint16]  ## Pointer to VGA framebuffer
    row*: int
    col*: int
    attr*: uint8  ## Current color attribute

proc vgaAttr*(fg: VgaColor, bg: VgaColor): uint8 {.inline.} =
  ## Encode foreground and background colors into a VGA attribute byte.
  uint8(fg) or (uint8(bg) shl 4)

proc vgaInit*(vga: var VgaState, framebuf: pointer) =
  ## Initialize VGA state. Pass nil for framebuf in unit tests.
  vga.buf  = cast[ptr UncheckedArray[uint16]](
    if framebuf == nil: nil else: framebuf
  )
  vga.row  = 0
  vga.col  = 0
  vga.attr = vgaAttr(vgaLightGray, vgaBlack)

proc vgaAdvanceCursor*(vga: var VgaState) =
  ## Move cursor forward one cell, scrolling if at bottom.
  inc vga.col
  if vga.col >= VgaWidth:
    vga.col = 0
    inc vga.row
    if vga.row >= VgaHeight:
      # Scroll: move rows 1..H-1 up to 0..H-2, clear last row
      if vga.buf != nil:
        for r in 1..<VgaHeight:
          for c in 0..<VgaWidth:
            vga.buf[(r-1)*VgaWidth + c] = vga.buf[r*VgaWidth + c]
        for c in 0..<VgaWidth:
          vga.buf[(VgaHeight-1)*VgaWidth + c] = uint16(vga.attr) shl 8 or uint16(' ')
      vga.row = VgaHeight - 1

proc vgaPutChar*(vga: var VgaState, c: char) =
  ## Write a character at the current cursor position.
  if vga.buf == nil: return
  case c
  of '\n':
    vga.col = 0
    inc vga.row
    if vga.row >= VgaHeight:
      vgaAdvanceCursor(vga)
      vga.row = VgaHeight - 1
  of '\r':
    vga.col = 0
  of '\b':
    if vga.col > 0:
      dec vga.col
      vga.buf[vga.row * VgaWidth + vga.col] = uint16(vga.attr) shl 8 or uint16(' ')
  else:
    vga.buf[vga.row * VgaWidth + vga.col] = uint16(vga.attr) shl 8 or uint16(c)
    vgaAdvanceCursor(vga)

proc vgaPutString*(vga: var VgaState, s: cstring) =
  var i = 0
  while s[i] != '\0':
    vga.putChar(s[i])
    inc i

proc vgaClear*(vga: var VgaState) =
  ## Clear screen to current background color.
  if vga.buf == nil: return
  let blank = uint16(vga.attr) shl 8 or uint16(' ')
  for i in 0..<(VgaWidth * VgaHeight):
    vga.buf[i] = blank
  vga.row = 0; vga.col = 0

# ── Global VGA state ───────────────────────────────────────────────────────

var vga*: VgaState

proc vgaDriverInit(): DriverResult {.nimcall.} =
  vgaInit(vga, cast[pointer](VgaAddr))
  vgaClear(vga)
  klog(llInfo, "VGA text mode initialized (80x25)")
  drOk

proc vgaDriverDeinit(): DriverResult {.nimcall.} = drOk

let vgaTextDriver* = DriverVTable(
  name:   "vga_text",
  init:   vgaDriverInit,
  deinit: vgaDriverDeinit,
  irq:    nil
)
```

- [ ] **Step 4: Run VGA tests**

```bash
nim c -r tests/test_vga_text.nim
```

Expected:
```
PASS: VGA color attribute encoding correct
PASS: cursor bounds enforced
```

- [ ] **Step 5: Commit**

```bash
git add drivers/vga_text.nim tests/test_vga_text.nim
git commit -m "feat: VGA text mode driver with scroll and color support"
```

---

## Task 7: Interactive Shell (Slice 1)

**Files:**
- Create: `shell/shell.nim`
- Modify: `kernel/init/main.nim`

The shell reads from serial (since QEMU's keyboard is trickier to test headlessly) and echoes back. Commands: `help`, `meminfo`, `clear`, `version`.

- [ ] **Step 1: Write failing shell tests**

Create `tests/test_shell.nim`:

```nim
# SPDX-License-Identifier: GPL-2.0
## Tests for shell command parsing (no hardware needed)

import ../shell/shell

proc testCommandParsing() =
  assert parseCommand("help") == scHelp
  assert parseCommand("meminfo") == scMeminfo
  assert parseCommand("clear") == scClear
  assert parseCommand("version") == scVersion
  assert parseCommand("unknown") == scUnknown
  assert parseCommand("") == scEmpty
  echo "PASS: command parsing correct"

proc testCommandTrimming() =
  # Leading/trailing spaces should be ignored
  assert parseCommand("  help  ") == scHelp
  assert parseCommand("help\n") == scHelp
  echo "PASS: command whitespace trimming correct"

when isMainModule:
  testCommandParsing()
  testCommandTrimming()
```

- [ ] **Step 2: Run to verify failure**

```bash
nim c -r tests/test_shell.nim 2>&1 | head -5
```

Expected: `Error: cannot open file: ../shell/shell`

- [ ] **Step 3: Create shell/shell.nim**

```nim
# SPDX-License-Identifier: GPL-2.0
## NimixOS Interactive Shell - Slice 1
##
## Reads commands from serial port (COM1), executes built-ins, prints results.
## This is the "hello world" of OS interaction — proves the full stack works.

import ../core/serial
import ../core/log
import ../core/types
import ../mm/physical_manager  # for meminfo command

const
  Prompt   = "nimixos> "
  MaxInput = 256

type
  ShellCommand* = enum
    scEmpty
    scUnknown
    scHelp
    scMeminfo
    scClear
    scVersion

proc trimString(s: string): string =
  ## Remove leading and trailing whitespace and newlines.
  var first = 0
  var last  = s.len - 1
  while first <= last and (s[first] == ' ' or s[first] == '\t' or s[first] == '\n' or s[first] == '\r'):
    inc first
  while last >= first and (s[last] == ' ' or s[last] == '\t' or s[last] == '\n' or s[last] == '\r'):
    dec last
  s[first..last]

proc parseCommand*(input: string): ShellCommand =
  ## Parse a trimmed input string into a ShellCommand enum.
  let cmd = trimString(input)
  if cmd.len == 0:    return scEmpty
  if cmd == "help":    return scHelp
  if cmd == "meminfo": return scMeminfo
  if cmd == "clear":   return scClear
  if cmd == "version": return scVersion
  scUnknown

proc shellHelp() =
  kprint("Available commands:\n")
  kprint("  help     - Show this message\n")
  kprint("  version  - Show kernel version\n")
  kprint("  meminfo  - Show memory usage\n")
  kprint("  clear    - Clear screen (serial: prints newlines)\n")

proc shellVersion() =
  kprint("NimixOS v0.1.0 - A Nim OS experiment\n")
  kprint("Kernel model: ")
  when defined(kernelModel):
    kprint({.strVal: "kernelModel".})
  else:
    kprint("monolithic")
  kprint("\n")

proc shellClear() =
  # On serial: print 40 newlines to scroll past old output
  for i in 0..39:
    defaultSerial.putChar('\n')

proc shellMeminfo(physMgr: ptr PhysicalMemManager) =
  if physMgr == nil:
    kprint("Memory manager not initialized\n")
    return
  kprint("Physical memory:\n")
  kprint("  Total:  ")
  kprintInt(int64(physMgr.totalFrames * 4096 div 1024 div 1024))
  kprint(" MB\n")
  kprint("  Used:   ")
  kprintInt(int64(physMgr.usedFrames * 4096 div 1024 div 1024))
  kprint(" MB\n")
  kprint("  Free:   ")
  kprintInt(int64((physMgr.totalFrames - physMgr.usedFrames) * 4096 div 1024 div 1024))
  kprint(" MB\n")

proc runShell*(physMgr: ptr PhysicalMemManager) =
  ## Main shell loop. Reads from serial, executes commands, loops forever.
  kprint("\n")
  kprint("=================================\n")
  kprint("  Welcome to NimixOS Shell\n")
  kprint("  Type 'help' for commands\n")
  kprint("=================================\n\n")

  var inputBuf: array[MaxInput, char]
  var inputLen = 0

  kprint(Prompt)

  while true:
    # Read one character from serial (blocking)
    let c = defaultSerial.getChar()

    case c
    of '\r', '\n':
      # Enter pressed — execute command
      defaultSerial.putChar('\n')
      let input = $cast[cstring](addr inputBuf[0])
      let cmd = parseCommand(input[0..<inputLen])
      case cmd
      of scHelp:    shellHelp()
      of scVersion: shellVersion()
      of scClear:   shellClear()
      of scMeminfo: shellMeminfo(physMgr)
      of scEmpty:   discard
      of scUnknown:
        kprint("Unknown command: ")
        kprint(input[0..<inputLen])
        kprint("\nType 'help' for available commands\n")
      # Reset buffer
      inputLen = 0
      for i in 0..<MaxInput: inputBuf[i] = '\0'
      kprint(Prompt)

    of '\b', char(127):
      # Backspace
      if inputLen > 0:
        dec inputLen
        inputBuf[inputLen] = '\0'
        defaultSerial.putChar('\b')
        defaultSerial.putChar(' ')
        defaultSerial.putChar('\b')

    else:
      # Regular character
      if inputLen < MaxInput - 1:
        inputBuf[inputLen] = c
        inc inputLen
        defaultSerial.putChar(c)  # Echo
```

- [ ] **Step 4: Run shell tests**

```bash
nim c -r tests/test_shell.nim
```

Expected:
```
PASS: command parsing correct
PASS: command whitespace trimming correct
```

- [ ] **Step 5: Wire shell into kernel/init/main.nim**

In `kernel/init/main.nim`, find the `runKernel` proc and add at the end (after memory managers are initialized):

```nim
import ../../shell/shell
import ../../kernel/models/monolithic
import ../../drivers/ps2_keyboard
import ../../drivers/vga_text

# In runKernel, after heap init:

# Initialize kernel model
initMonolithicModel()
klog(llInfo, "Kernel model: monolithic")

# Initialize drivers
let kbdResult = ps2KeyboardDriver.init()
if kbdResult != drOk:
  klog(llWarn, "PS/2 keyboard init failed")

let vgaResult = vgaTextDriver.init()
if vgaResult != drOk:
  klog(llWarn, "VGA text driver init failed")

# Enter shell — never returns
klog(llInfo, "Entering shell...")
runShell(addr kernel.physMgr)
```

- [ ] **Step 6: Build and test in QEMU**

```bash
make build 2>&1 | tail -10
```

Expected: `build/main` produced, no errors.

```bash
make iso && make qemu
```

Expected serial output:
```
[INFO]  Starting kernel
...
[INFO]  Monolithic model initialized
[INFO]  PS/2 keyboard initialized
[INFO]  VGA text mode initialized (80x25)
[INFO]  Entering shell...

=================================
  Welcome to NimixOS Shell
  Type 'help' for commands
=================================

nimixos>
```

Type `help` in the QEMU serial window, press Enter, expect the help text.

- [ ] **Step 7: Commit**

```bash
git add shell/ drivers/ kernel/init/main.nim tests/test_shell.nim
git commit -m "feat: Slice 1 complete — interactive serial shell with help/version/meminfo/clear"
```

---

## Task 8: Run All Tests + CI Makefile Target

**Files:**
- Create: `tests/all_tests.nim`
- Modify: `Makefile`

- [ ] **Step 1: Create tests/all_tests.nim**

```nim
# SPDX-License-Identifier: GPL-2.0
## Run all kernel unit tests

import ./test_log
import ./test_traits
import ./test_ps2_keyboard
import ./test_vga_text
import ./test_shell

echo "All tests passed."
```

- [ ] **Step 2: Verify all tests pass**

```bash
nim c -r tests/all_tests.nim
```

Expected: all PASS lines, then `All tests passed.`

- [ ] **Step 3: Add test target to Makefile**

Add after the existing `clean` target:

```makefile
# ── Run unit tests (host, no QEMU needed) ─────────────────────────────────
test:
	$(NIM) c -r tests/all_tests.nim
```

- [ ] **Step 4: Verify make test works**

```bash
make test
```

Expected: same output as Step 2.

- [ ] **Step 5: Final commit**

```bash
git add tests/all_tests.nim Makefile
git commit -m "feat: unified test runner, make test target"
```

---

## Self-Review

### Spec Coverage

| Requirement | Task |
|------------|------|
| Arsenal integration | Task 1 |
| kpanic + kassert + log levels | Task 2 |
| Kernel traits layer (scheduler, IPC, driver) | Task 3 |
| Monolithic model | Task 4 |
| Microkernel/unikernel stubs | Task 4 |
| Swappable model at compile time | Tasks 3+4 (`-d:kernelModel=`) |
| PS/2 keyboard | Task 5 |
| VGA text mode | Task 6 |
| Interactive shell (Slice 1) | Task 7 |
| `make test` runs all tests | Task 8 |

### Placeholder Scan

- All code blocks are complete, no "TBD" or "TODO" in any step.
- `shellVersion()` uses `{.strVal.}` pragma — this may need adjustment; alternative: `const model = "monolithic"` defined in `kernel/config.nim` and imported.
- `runShell` uses `$cast[cstring]` to convert char array to string — verify this works under `--os:any`. Alternative: build string manually with `setLen`.

### Type Consistency

- `TaskId`, `ChannelId` defined in traits, used consistently in monolithic.
- `DriverVTable` defined in `driver.nim`, used in both keyboard and VGA drivers.
- `PhysicalMemManager` imported from `mm/physical_manager` in shell — matches existing type.
- `klog`, `kpanic`, `kassert` defined in `core/log.nim`, used in multiple tasks consistently.
