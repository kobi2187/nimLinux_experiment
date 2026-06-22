# NimixOS Service Scaffold Pattern

## Core Insight

A kernel module and a userspace server are the **same logic** with different **call paths** around it. Write the logic once; swap the scaffold at compile time.

## Three-Layer Structure

```
servers/<name>/
  <name>_logic.nim      ← Pure algorithm library. Zero OS assumptions.
  <name>_kmod.nim       ← Kernel module scaffold (ring 0, direct calls)
  <name>_server_elf.nim ← Userspace ELF scaffold (ring 3, PIE, IPC)
servers/<name>.nim       ← Compat shim: re-exports kmod for existing callers
```

## The Logic Layer

The logic module receives ALL dependencies via an injected interface object:

```nim
type
  MyServiceIface* = object
    log*:     proc(msg: cstring) {.nimcall.}
    publish*: proc(topic: cstring; data: pointer; len: int) {.nimcall.}
    putChar*: proc(c: char) {.nimcall.}

  MyService* = object
    iface*: MyServiceIface
    # ... mutable state ...

proc myServiceInit*(svc: var MyService; iface: MyServiceIface) = ...
proc myServiceHandleMsg*(svc: var MyService; data: ptr byte; len: int) = ...
```

No imports of `serial`, `log`, `event_server` — those are injected. The logic file
is testable on Linux without any kernel code compiled in.

## The Kernel Module Scaffold

```nim
import <name>_logic
import ../../core/serial, ../../kernel/event_server, ../../core/log

proc kmodLog(msg: cstring) {.nimcall.}    = klog(llInfo, msg)
proc kmodPublish(...) {.nimcall.}         = eventPublish(topic, data, dataLen)
proc kmodPutChar(c: char) {.nimcall.}     = defaultSerial.putChar(c)

let kmodIface = MyServiceIface(log: kmodLog, publish: kmodPublish, ...)

proc myServiceInit*()  = myLogicInit(svc, kmodIface)
proc myServiceTick*()  = ... recv from mailbox ... myLogicHandleMsg(svc, ...)
```

Compiled into the kernel binary. Called directly — zero IPC overhead.

## The Userspace ELF Scaffold

```nim
import <name>_logic

proc nimixWrite(buf: pointer; len: int) {.importc, cdecl.}  # kernel ABI
proc nimixExit(code: int) {.importc, cdecl.}

proc stubLog(msg: cstring) {.nimcall.}    = ... nimixWrite ...
proc stubPublish(...) {.nimcall.}         = ... capability IPC call ...
proc stubPutChar(c: char) {.nimcall.}     = nimixWrite(unsafeAddr c, 1)

proc appMain*() {.exportc.} =
  myLogicInit(svc, MyServiceIface(log: stubLog, ...))
  while true: ... recv from capability channel ... myLogicHandleMsg(...)
```

Compiled as PIE ELF (`-fPIC -pie`). Loader places it at any address.
ABI symbols (`nimixWrite`, `nimixExit`) resolved by kernel at load time.

## Kernel Model Mapping

| Model | Where service runs | Call path | Overhead |
|-------|-------------------|-----------|----------|
| Monolithic | kernel binary (kmod) | direct function call | ~ns |
| SASOS | same address space (kmod + capability gate) | direct call + cap check | ~ns |
| Microkernel | separate PIE ELF process | IPC message + schedule | ~µs |

The logic library is **identical** in all three cases. Only the scaffold changes.

## Hardware Access Abstraction

For services that touch hardware (drivers), the same pattern applies one level
deeper — abstract hardware access via a `HwAccess` object:

```nim
type HwIface* = object
  inb*:  proc(port: uint16): uint8 {.nimcall.}
  outb*: proc(port: uint16; val: uint8) {.nimcall.}
```

- Ring 0: inject real `inb`/`outb` instructions
- Ring 3: inject capability-gated port I/O calls (microkernel)
- Tests: inject mock that records calls

## Proof of Concept

`servers/ping/` is the reference implementation:
- `ping_logic.nim` — handles one message, publishes "pong"
- `ping_kmod.nim` — kernel-side, wired to serial + eventPublish
- `ping_server_elf.nim` — PIE ELF stub (IPC stubs pending capability layer)

## What's Not Yet Done

- `ping_server_elf.nim` IPC stubs: replace `discard` with capability channel recv
- Virtual region allocator for SASOS: currently falls back to kernel heap alloc
- Relocation support in `elfLoad()`: needed to actually run PIE ELFs
- `--os:nimix` Nim compiler target: replaces `--os:standalone` + panicoverride hack
