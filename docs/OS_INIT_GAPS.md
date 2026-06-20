# NimixOS — Boot Init: What Mature OSes Do That We Don't Yet

## What BeOS, QNX, and Linux Do On Init

### Linux

1. **Memory subsystem** — zones, slab/slub allocator, vmalloc ✓ *(we have basic physical/virtual/heap)*
2. **CPU setup** — GDT, IDT, TSS, per-CPU areas, FPU state ⚠ *(we have IDT stub, no TSS/FPU)*
3. **ACPI table parsing** — find MADT → discover CPUs, IOAPICs, interrupt routing
4. **Interrupt controller init** — PIC or APIC/IOAPIC programming, IRQ routing table
5. **Timer init** — PIT or HPET or TSC deadline → gives the scheduler a heartbeat
6. **Driver subsystem (`initcall`)** — scans a table of `__init` functions in link order: bus drivers first (PCI enumeration), then device drivers register themselves
7. **PCI bus scan** — walks PCI config space, builds device tree, assigns BARs
8. **Root filesystem mount** — finds initramfs or real root, mounts it
9. **`/sbin/init` (PID 1)** — userspace begins; systemd reads unit files, starts services in dependency order
10. **Device nodes** — udev watches kernel uevents, creates `/dev` entries
11. **VFS layer** — mounts proc, sysfs, devtmpfs

### QNX (microkernel)

1. **`procnto` (process manager) starts as PID 1** — handles spawn, wait, resource managers
2. **Startup script** — explicit ordered list: start each server binary in sequence
3. **`io-pkt`** — network stack as a separate process
4. **`devb-*` / `devc-*`** — block and character device drivers (each an isolated process)
5. **Resource manager framework** — each driver registers a pathname in the filesystem namespace (`/dev/ser1`, `/dev/hd0`); all IPC is POSIX message passing
6. **`slogger2`** — system-wide structured logging service (all drivers log to it)
7. **No implicit driver scanning** — everything is declared explicitly; nothing loads unless listed

### BeOS

1. **`kernel_server`** — sets up the hardware abstraction layer
2. **`device_manager`** — scans buses (PCI, ISA), builds a device tree
3. **Driver probing** — walks `/boot/beos/system/add-ons/kernel/drivers/dev/`; each driver's `probe()` is called with the device tree node; if it claims the device, it is loaded
4. **`app_server`** — display/window compositor starts early (GUI came up before most services — a BeOS hallmark)
5. **`registrar`** — maintains running application registry (open apps, MIME type associations)
6. **`net_server`** — networking
7. **`media_server`** — real-time audio/video routing (media was first-class in BeOS)
8. **Launch daemon** — reads scripts to start remaining services

---

## NimixOS Gap Map

| Category | What's Needed | Priority |
|----------|--------------|----------|
| **Interrupt controller** | PIC 8259 or APIC init + IRQ routing table | 🔴 Critical — keyboard IRQ deaf without this |
| **Timer (PIT/HPET)** | Scheduler heartbeat, sleep, preemption | 🔴 Critical — no preemption without a tick |
| **TSS + ring switch** | Task State Segment for ring 0↔3 transitions, FPU save/restore | 🔴 Critical for any userspace |
| **PCI bus scan** | Walk config space, enumerate devices, assign BARs | 🟠 High — prerequisite for NIC, disk, GPU drivers |
| **ACPI basic** | Parse MADT for CPU count, IOAPIC addresses, IRQ routing | 🟠 High — needed before SMP or real interrupt routing |
| **Driver probe loop** | Registry of `DriverVTable`s, call `init()` in order, log results | 🟡 Medium — vtables exist, registry does not |
| **Device namespace** | `/dev`-style path registry; drivers register by name | 🟡 Medium — needed for VFS and `ls /dev` in shell |
| **Filesystem (VFS + FAT32)** | Mount disk images, read files, abstract over device | 🟡 Medium — needed to load programs |
| **ELF loader** | Parse ELF, map segments into address space, jump to entry | 🟡 Medium — needed to run any binary |
| **Syscall table** | Ring 3 → ring 0 call gate (`syscall`/`sysenter` instruction) | 🟡 Medium — needed for userspace programs |
| **Preemptive scheduler** | Timer IRQ fires → save context → pick next task → restore | 🔴 Critical — current scheduler is cooperative only |
| **`dmesg` ring buffer** | Circular log buffer readable after boot (not just serial) | 🟢 Nice — we have `klog` to serial, no ring yet |

---

## NimixOS Architecture Additions

### WASM Process Model

Applications in NimixOS run as **WebAssembly modules** rather than native ELF binaries. This aligns perfectly with the SASOS model:

- **Isolation without MMU rings** — the WASM sandbox is the isolation boundary; the language/runtime enforces it, not page tables
- **Capability-gated imports** — a WASM module can only call host functions (syscalls, drivers, IPC) that have been explicitly granted via a capability token at load time
- **Portable** — the same `.wasm` binary runs on any architecture NimixOS is ported to
- **Verifiable** — the WASM bytecode is type-checked before execution; malformed code is rejected at load time, not at crash time

```
App (.wasm)
  └── imports: [ipc.send, fs.read, event.subscribe]   ← capability-checked at load
        └── host runtime (Nim WASM interpreter or WASI layer)
              └── kernel capabilities (SipCapability tokens gate each import)
```

Implementation path:
1. Embed a minimal WASM interpreter (e.g. `wasm3` — C, zero dependencies, fits in kernel)
2. WASM host functions map to capability-checked kernel calls
3. Each running WASM instance is a SIP (Software Isolated Process) with its own capability set

### Event Server

Inspired by BeOS's `BMessage`/`BMessenger` system and QNX's pulse model. The event server is a kernel-resident publish/subscribe broker:

```
Producer (driver, app, kernel subsystem)
  └── event_server.publish(topic, payload)
        └── delivers to all subscribed SIPs
              └── Consumer wakes from event_server.wait(topic)
```

**Key operations:**

| Call | Description |
|------|-------------|
| `event.subscribe(topic) → token` | Register interest in a topic; returns a wait token |
| `event.wait(token) → Event` | Block until an event arrives on this token |
| `event.poll(token) → Option[Event]` | Non-blocking check |
| `event.publish(topic, payload)` | Emit an event to all subscribers |
| `event.waitAll(tokens[]) → Event` | Block until ANY of the listed tokens fires (select-style) |

**Use cases:**

- **Process completion** — `event.wait(pid_exit(pid))` blocks until a WASM process exits
- **Device hotplug** — driver publishes `dev.pci.added`; device manager subscribes
- **IPC rendezvous** — two apps synchronize through `event.publish`/`event.wait` instead of shared memory
- **Timer events** — kernel publishes `timer.tick` at configurable Hz; apps subscribe instead of busy-waiting
- **Filesystem changes** — VFS publishes `fs.changed(path)`; file watchers subscribe

**Implementation fits SASOS perfectly:** the event server is a kernel module (not a separate process), so publish/subscribe has zero IPC overhead — it's a direct call into the kernel's event table. But the API is identical to what a microkernel would expose through message passing, so it remains portable across models.

---

## Immediate Next Steps (Priority Order)

1. **PIC 8259 init** → IRQ routing → keyboard fires → PS/2 driver activates
2. **PIT timer** → 100Hz tick → preemptive scheduler → `sleep()` works
3. **TSS + syscall gate** → ring 0/3 split → userspace possible
4. **Driver registry** → `probe()` loop at boot → dmesg shows found devices
5. **Event server** → pub/sub backbone → process coordination
6. **WASM runtime** (`wasm3`) → first app sandbox
7. **PCI scan** → enumerate QEMU's virtual devices
8. **VFS + FAT32** → mount disk image → load `.wasm` from files
