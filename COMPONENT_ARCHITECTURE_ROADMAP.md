# NimixOS Component-Focused Architecture Roadmap

## Executive Summary

This roadmap reimagines NimixOS kernel development from a **component and library-first perspective**. The key insight: Every architectural style (monolithic, microkernel, single-address-space, hybrid) needs the same 14 core components—they differ only in *how* those components are orchestrated.

By building reusable, well-tested libraries with clear interfaces, you unlock multiple implementation strategies and enable parallel development.

---

## Part 1: Component Taxonomy (20 Components)

### Layer 0: CPU & Hardware Primitives (No dependencies)

**1. CPU Primitives Library** - Abstraction over x86_64 operations (mostly complete)
- Control registers (CR0-CR4, CR8)
- MSR operations
- I/O port operations
- Interrupt control (cli, sti, hlt)
- TLB operations
- Timestamp counter (rdtsc)
- CPUID support

**2. Atomic Operations Library** - Lock-free synchronization primitives (complete)
- Memory barriers (compiler, load, store, full)
- Atomic load/store/exchange with memory ordering
- Compare-and-swap (strong/weak)
- Atomic fetch-op (add, sub, or, and, xor)

**3. Core Types** - Foundational types (stable)
- PhysAddr, VirtAddr distinct types
- Result[T, E] error handling
- Option[T] for nullable values
- Alignment and bitwise utilities

---

### Layer 1: Synchronization Primitives

**4. Spinlock Library** - Mutual exclusion
- SpinLock (basic test-and-set with backoff)
- TicketLock (FIFO fairness)
- RawSpinLock (minimal overhead)
- RWSpinLock (from arsenal library)
- SpinLockGuard (RAII)

**5. Channel & Queue Library** - Lock-free message passing
- SPSC queue (wait-free)
- MPMC queue
- Bounded vs unbounded variants
- Integration with arsenal library

**6. Condition Variable & Event Library** - Wait-notify synchronization
- CondVar (condition variable)
- Event (binary and counting)
- Semaphore (counting semaphore)
- Barrier (synchronization point)

---

### Layer 2: Memory Management

**7. Physical Memory Allocator** - Frame allocation (partial)
- Allocate/deallocate frames
- Zone management (DMA, DMA32, Normal)
- Buddy allocator variant
- Statistics and debugging

**8. Virtual Memory Manager** - Page table management
- Page table creation/destruction
- Virtual address space creation/destruction
- Map/unmap operations
- Permission management
- TLB shootdown coordination

**9. Heap Allocator** - General-purpose malloc/free
- Allocate/free/realloc/calloc
- Alignment support
- Buddy or free-list strategy
- Debug poisoning and validation

---

### Layer 3: CPU & Task Management

**10. Interrupt & Exception System** - IDT and ISR dispatching
- IDT initialization
- Exception handlers registration
- Hardware interrupt handlers
- Exception context structure

**11. Task/Thread Library** - Task representation
- Task creation/destruction
- Task states (ready, running, sleeping, etc.)
- Context storage
- Priority levels

**12. Scheduler Library** - Task scheduling
- Scheduling algorithms (round-robin, priority, CFS)
- Context switching primitives
- Per-CPU scheduler queues
- Load balancing

---

### Layer 4: Device & System Integration

**13. Device Abstraction Layer** - Generic device interface
- Device registration/discovery
- Device tree
- Driver loading/unloading
- Interrupt routing

**14. System Call Interface** - User-kernel boundary
- Syscall table management
- Register argument extraction
- Return value handling
- Security boundary enforcement

**15. Timer & Clock Library** - Timekeeping
- System clock management
- Hardware timer programming
- Soft timer queue
- Performance counters

**16. Logging & Debug Library** - Kernel logging
- Serial port output (exists as core/serial.nim)
- Log levels and filtering
- Structured logging
- Debugger hooks

---

### Layer 5: Filesystem & IPC

**17. VFS Abstraction Layer** - Filesystem abstraction
- Inode interface
- Filesystem driver interface
- File descriptor management
- Mount points and path traversal

**18. Filesystem Drivers** - Concrete implementations
- FAT32 (simpler, first)
- ext2 (Unix-like)
- ext4 (advanced, optional)

**19. IPC Library** - Inter-process communication
- Message passing primitives
- Shared memory regions
- Pipes and message queues
- Capability-based access control

**20. Bootloader Interface** - Boot protocol handling
- Boot information parsing
- Bootloader protocol abstraction
- Early memory setup
- CPU initialization sequencing

---

## Part 2: Dependency Graph & Build Order

### Dependencies Hierarchy

```
LAYER 0 (No dependencies):
  ├─ CPU Primitives
  ├─ Core Types
  └─ Boot Info

LAYER 1 (Depends on Layer 0):
  ├─ Atomics
  ├─ Spinlock
  ├─ Channels
  └─ Logging

LAYER 2 (Depends on Layer 1):
  ├─ Condition Variables
  ├─ Physical Memory
  ├─ Interrupt System
  └─ Timer

LAYER 3 (Depends on Layer 2):
  ├─ Virtual Memory
  ├─ Heap Allocator
  ├─ Task Library
  └─ Device Abstraction

LAYER 4 (Depends on Layer 3):
  ├─ Scheduler
  ├─ IPC Library
  ├─ VFS Abstraction
  └─ System Calls

LAYER 5 (Final Integration):
  └─ Kernel Main
```

### Recommended Parallel Build Strategy

**Phase 1: Foundation (Sequential - 2 weeks)**
1. CPU Primitives & Atomic Ops (review/finalize)
2. Boot Information Parsing

**Phase 2: Synchronization (Parallel - 2-3 weeks)**
- Track A: Spinlock variants + RWLock
- Track B: Channel/Queue wrappers
- Track C: Condition variables & semaphores

**Phase 3: Memory Management (Parallel - 3-4 weeks)**
- Track A: Physical memory enhancements
- Track B: Virtual memory manager
- Track C: Heap allocator

**Phase 4: Interrupts & Tasks (Parallel - 3 weeks)**
- Track A: Interrupt system & exceptions
- Track B: Task library & context switching
- Track C: Scheduler implementation

**Phase 5: Device & Hardware (Parallel - 2-3 weeks)**
- Track A: Timer & clock system
- Track B: Device abstraction layer
- Track C: System call interface

**Phase 6: Storage & IPC (Parallel - 4-5 weeks)**
- Track A: VFS layer
- Track B: FAT32 & ext2 drivers
- Track C: IPC library

**Phase 7: Integration (Sequential - 1 week)**
- Wire all components together
- End-to-end system validation

---

## Part 3: Architectural Composition Patterns

The power of this approach: **Use the same 14 components to build different architectures**.

### Option A: Monolithic Kernel (Like Linux)

```
Everything in one address space, shared heap, global scheduler
```

**Implementation:**
```nim
# kernel/init/main.nim
var kernel: Kernel
kernel.physMgr = initPhysicalMemManager()
kernel.virtMgr = initVirtualMemManager(kernel.physMgr)
kernel.heapMgr = initHeapAllocator(kernel.physMgr, kernel.virtMgr)
kernel.taskMgr = initTaskManager(kernel.heapMgr)
kernel.schedMgr = initScheduler(kernel.taskMgr)
kernel.intSys = initInterruptSystem()
kernel.vfs = initVFS(kernel.heapMgr)
kernel.devices = initDeviceManager(kernel.heapMgr)
# ... everything in one address space, one privilege level
```

**Characteristics:**
- ✅ Maximum performance (no domain transitions)
- ✅ Simpler initially
- ❌ One bug crashes everything
- ❌ Device drivers crash kernel

---

### Option B: Microkernel (Like seL4)

```
Minimal kernel + user-space services
```

**Implementation:**
```nim
# Kernel keeps minimal subset:
kernel.physMgr = initPhysicalMemManager()
kernel.virtMgr = initMinimalVirtualMemManager()
kernel.intSys = initInterruptSystem()
kernel.taskMgr = initTaskManager()
kernel.schedMgr = initScheduler()
kernel.ipc = initIPCSystem()  # Primary communication

# User-space services:
# - Device drivers as tasks
# - VFS as service
# - Filesystem drivers as tasks
```

**Characteristics:**
- ✅ Driver failures isolated
- ✅ High security
- ❌ Performance overhead from IPC
- ❌ Complex debugging

---

### Option C: Single Address Space OS (Like Singularity)

```
Single address space with type-safe regions enforced by compiler
```

**Implementation:**
```nim
# All in one address space but type-separated:
type
  KernelHeapRegion = object
  AppHeapRegion = object
  DriverHeapRegion = object

# Components same, but type-safe isolation:
kernel.virtMgr = initVirtualMemManager()  # Single space
kernel.heapMgr = initTypedHeapAllocator()  # Typed regions
kernel.taskMgr = initTaskManager()
# Type safety prevents cross-region access at compile time
```

**Characteristics:**
- ✅ Very high performance (no switches)
- ✅ Strong compile-time safety
- ❌ All code must be type-safe
- ❌ Language constraint

---

### Option D: Hybrid (Combination)

```
Monolithic kernel core + user-space isolated services
```

**Implementation:**
```nim
# Kernel core (monolithic):
kernel.physMgr = initPhysicalMemManager()
kernel.virtMgr = initVirtualMemManager()
kernel.heapMgr = initHeapAllocator()
kernel.taskMgr = initTaskManager()
kernel.schedMgr = initScheduler()
kernel.intSys = initInterruptSystem()

# Critical services (isolated but co-located):
kernel.vfs = initVFSService()
kernel.criticalDevices = initCriticalDeviceManager()

# Non-critical services (user-space tasks)
# Network stack, app drivers, etc.
```

**Characteristics:**
- ✅ Performance + isolation
- ✅ Best of both worlds
- ✅ Flexible fault tolerance
- ❌ Most complex
- ❌ Complex fallback mechanisms

---

## Part 4: Example Compositions

### Example 1: Adding a Device Driver (No Kernel Recompile)

```nim
# New driver using component interfaces
import sync/locks
import dev/device
import kern/interrupts

type
  NetworkDevice = ref object
    lock: SpinLock
    buffers: seq[pointer]

proc networkInterruptHandler(ctx: ptr ExceptionContext) =
  let device = getDevice("network")
  device.lock.acquire()
  defer: device.lock.release()

  # Handle interrupt using common components
  let packets = device.readPackets()
  for packet in packets:
    ipc.send(NetworkServiceTask, packet)
```

### Example 2: Switching from Monolithic to Hybrid

```nim
# Start: Monolithic kernel (all in-kernel)
kernel.initAll()

# Transition: Move VFS to user-space
# Change in kernel/init/main.nim:
kernel.vfs = nil  # Don't initialize in kernel
kernel.ipc.registerService("vfs", VFSUserSpaceTask)

# Components stay the same - only orchestration changes!
```

### Example 3: Testing Component in Isolation

```nim
# Can test without full system
import mm/physical_manager
import core/types

proc testPhysicalAllocator() =
  var mgr: PhysicalMemManager
  mgr.init(1000)  # 1000 frames

  let frames = mgr.allocFrames(100)
  # Test in controlled environment, no VM/scheduler/IPC needed
```

---

## Part 5: Testing Strategy

Each component should have:

- [ ] **Unit Tests** - 100% proc coverage in isolation
- [ ] **Integration Tests** - Works with dependencies
- [ ] **Performance Tests** - Meets expected targets
- [ ] **Stress Tests** - Under load conditions
- [ ] **Error Cases** - All error paths tested
- [ ] **Memory Safety** - No leaks, no double-free
- [ ] **Type Safety** - Effective use of Nim's type system
- [ ] **Documentation** - Clear usage examples
- [ ] **Code Review** - Peer reviewed

### End-to-End Validation

```
Boot → Init Phases → Serial Output → Memory Allocation → Task Creation
  → Context Switch → Syscall → File I/O → App Launch
```

---

## Part 6: Timeline & Teams

**Total Duration:** 16-20 weeks (4-5 months)

| Phase | Duration | Parallel Tracks | Teams |
|-------|----------|-----------------|-------|
| Foundation | 2 weeks | Sequential | 1 |
| Sync Primitives | 2-3 weeks | 3 tracks | 3 teams |
| Memory Management | 3-4 weeks | 3 tracks | 3 teams |
| Interrupts & Tasks | 3 weeks | 3 tracks | 3 teams |
| Device & Hardware | 2-3 weeks | 3 tracks | 3 teams |
| Storage & IPC | 4-5 weeks | 3 tracks | 3 teams |
| Integration | 1 week | Sequential | All |

---

## Part 7: Key Decision Points (Easy to Change)

1. **Memory Allocator Strategy** - Buddy vs Free-List vs Slab
   - Component interface fixed by `Allocator` trait
   - Can swap implementations without kernel changes

2. **Scheduler Algorithm** - Round-robin vs Priority vs CFS vs Work-stealing
   - Component interface fixed by `Scheduler` trait
   - Can implement multiple, choose at init

3. **Architectural Style** - Monolithic vs Microkernel vs Single-Address-Space vs Hybrid
   - **All 14 components remain identical**
   - Switch by changing orchestration in `kernel/init/main.nim`

4. **Filesystem Support** - FAT32 vs ext2 vs ext4
   - Component interface fixed by `FilesystemDriver` trait
   - Multiple filesystems can coexist

5. **IPC Mechanism** - Message-passing vs Shared-memory vs Capability-based
   - Component interface fixed by `IPC` trait
   - Multiple mechanisms can coexist

---

## Part 8: How to Use This Roadmap

1. **Build Libraries First**: Each component is a standalone library with clear interface
2. **Test in Isolation**: Test components before integrating
3. **Compose Later**: Once components work, compose them into kernel
4. **Swap Implementations**: Change schedulers, allocators, etc. without touching other code
5. **Multiple Architectures**: Same components → different final systems

---

## Critical Files for Implementation

1. `/core/types.nim` - Core types pattern (stable, well-designed)
2. `/core/traits/allocator.nim` - Interface pattern to follow
3. `/sync/spinlock.nim` - Component interface reference
4. `/mm/physical_manager.nim` - Foundation for memory work
5. `/arch/x86_64/cpu_primitives.nim` - CPU abstraction pattern
6. `/arch/common/atomics.nim` - Atomic operations foundation
7. `/kernel/init/main.nim` - Orchestration example

---

## Next Steps

1. **Phase 1** - Finalize foundation components (2 weeks)
2. **Set up component testing framework** before implementation
3. **Parallelize work** - assign teams to different tracks
4. **Document interfaces as contracts** BEFORE coding
5. **Regular integration points** to catch dependency issues early

**Key Principle**: Build libraries, not a monolith. Compose libraries, not kernels.

---

**Research Date**: February 2026
**Approach**: Component-focused, composable architecture
**Flexibility**: Support monolithic, microkernel, single-address-space, and hybrid designs
