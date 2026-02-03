# Using Nim Libraries for OS Development

**Goal**: Leverage the Nim ecosystem to accelerate OS development while maintaining kernel compatibility.

## Strategic Overview

### What We CAN Use
- ✅ Standard library (core, minimal, no GC)
- ✅ Arsenal (lock-free, already provided)
- ✅ Libraries that don't require runtime
- ✅ Libraries compilable with `--gc:none`
- ✅ Pure Nim implementations

### What We CANNOT Use
- ❌ Async/await (we're writing the scheduler)
- ❌ Threading libraries (we're writing threading)
- ❌ Networking (device driver layer)
- ❌ GUI libraries
- ❌ Libraries depending on OS services we haven't implemented

---

## Core Libraries Available

### Standard Library (Always Available)

#### 1. **sequtils** - Sequence Operations
```nim
import sequtils

# Use for:
# - Filtering ready tasks
# - Mapping over processes
# - Finding elements in lists

let readyTasks = allTasks.filterIt(it.state == tsReady)
let priorityTasks = allTasks.sortedByIt(it.priority)
```

**Best for**: Task queues, process lists, filtering

---

#### 2. **strutils** - String Operations
```nim
import strutils

# Use for:
# - Parsing command lines
# - Converting numbers to strings
# - String manipulation for paths

let args = commandLine.split()
let hex = "0x1000".parseHexInt
```

**Best for**: Bootloader arguments, configuration parsing

---

#### 3. **strformat** - String Formatting
```nim
import strformat

# Use for:
# - Debug output formatting
# - Status messages
# - Log messages

kprint fmt"Process {pid}: allocated {pages} pages"
```

**Best for**: Kernel logging, debugging output

---

#### 4. **algorithm** - Sorting & Searching
```nim
import algorithm

# Use for:
# - Sorting task queues by priority
# - Binary search in memory maps
# - Finding free blocks

var queue = @[task1, task2, task3]
queue.sort((a, b) => cmp(a.priority, b.priority))
```

**Best for**: Priority queues, binary search for memory allocation

---

#### 5. **tables** - Hash Tables
```nim
import tables

# Use for:
# - Process lookup by PID
# - File descriptor tables
# - Device driver registration

var pidToProcess: Table[int, Process]
pidToProcess[123] = process
```

**Best for**: Fast lookups, hashtable-based caches

---

#### 6. **deques** - Double-ended Queues
```nim
import deques

# Use for:
# - Run queue (enqueue/dequeue from both ends)
# - Work stealing queues
# - Undo/redo stacks

var runQueue: Deque[Task]
runQueue.addLast(task)
let nextTask = runQueue.popFirst()
```

**Best for**: Scheduler queues, work-stealing

---

#### 7. **bitops** - Bit Operations
```nim
import bitops

# Use for:
# - Bitmap allocators (already used!)
# - Feature flags
# - Permission bits
# - CPU affinity masks

if bitTest(cpuMask, 0):
  # CPU 0 is available
```

**Best for**: Already using in physical memory manager

---

#### 8. **atomics** - Atomic Operations
```nim
import std/atomics

# Use for:
# - Lock-free counters
# - Atomic flags
# - Compare-and-swap

var counter: Atomic[uint64]
inc(counter, 1)
```

**Best for**: Lock-free synchronization, atomic operations

---

### Arsenal Library (Provided)

Arsenal is a **lock-free data structures library** perfect for kernel development.

#### 1. **LockFreeQueue**
```nim
import arsenal/lock_free_queue

# Use for:
# - Ready queue in scheduler
# - Work queue for load balancing
# - Interrupt event queue

var readyQueue: LockFreeQueue[Task]
readyQueue.enqueue(newTask)
let task = readyQueue.dequeue()
```

**Why Arsenal**: Zero-allocation, wait-free on common paths

#### 2. **LockFreeStack**
```nim
import arsenal/lock_free_stack

# Use for:
# - Work stealing from other CPUs
# - Memory block cache
# - Interrupt handler stack

var workStack: LockFreeStack[Job]
workStack.push(job)
let job = workStack.pop()
```

**Why Arsenal**: O(1) push/pop, no locking

#### 3. **LockFreeCounter**
```nim
import arsenal/lock_free_counter

# Use for:
# - Statistics (created, destroyed, switched)
# - Performance counters
# - Allocation tracking

var contextSwitches: LockFreeCounter
inc(contextSwitches)
```

**Why Arsenal**: Lock-free increment, safe for SMP

---

## Per-Phase Library Strategy

### Phase 1: Boot & Kernel Integration
```
Only use:
- strformat (logging during boot)
- algorithm (if sorting any boot data)
- bitops (if needed for CPU detection)

Avoid: Everything else (not initialized yet)
```

### Phase 2: I/O & Syscalls
```
Add:
- tables (syscall lookup table)
- sequtils (filtering processes)
- strutils (parsing args)
- arsenal/LockFreeQueue (ready queue)

Keep: phase 1 libs
```

### Phase 3: File System
```
Add:
- algorithm (directory sorting, inode caching)
- tables (dentry cache, inode lookup)

Keep: previous phases
```

### Phase 4: User Space & Security
```
Add:
- deques (process creation queue)

Keep: previous phases
```

### Phase 5: Advanced Features
```
Add:
- arsenal/LockFreeStack (work stealing)
- arsenal/LockFreeCounter (statistics)

Keep: all previous phases
```

---

## Implementation Patterns

### Ready Queue with Arsenal

**Before** (manual spinlock):
```nim
import sync/spinlock

type
  ReadyQueue = object
    lock: SpinLock
    tasks: seq[Task]

proc enqueue(queue: var ReadyQueue, task: Task) =
  queue.lock.acquire()
  defer: queue.lock.release()
  queue.tasks.add(task)
```

**After** (with Arsenal):
```nim
import arsenal/lock_free_queue

type
  ReadyQueue = object
    tasks: LockFreeQueue[Task]

proc enqueue(queue: var ReadyQueue, task: Task) =
  queue.tasks.enqueue(task)  # No locking!
```

### Statistics Tracking with Arsenal

**Before** (atomic fetch-and-add):
```nim
import sync/spinlock

var contextSwitches: uint64
var lock: SpinLock

proc incrementSwitches() =
  lock.acquire()
  defer: lock.release()
  inc(contextSwitches)
```

**After** (with Arsenal):
```nim
import arsenal/lock_free_counter

var contextSwitches: LockFreeCounter

proc incrementSwitches() =
  inc(contextSwitches)  # Atomic, no lock!
```

### Process Lookup Table

```nim
import tables

type
  ProcessTable = object
    # Map from PID to Process pointer
    processes: Table[int, Process]

proc findProcess(table: ProcessTable, pid: int): Option[Process] =
  # Option handles not-found case
  if pid in table.processes:
    some(table.processes[pid])
  else:
    none(Process)
```

### Priority Queue for Tasks

```nim
import algorithm, sequtils

type
  TaskQueue = object
    tasks: seq[Task]

proc selectNextTask(queue: var TaskQueue): Option[Task] =
  if queue.tasks.len == 0:
    return none(Task)

  # Find minimum priority (lower = higher priority)
  var minIdx = 0
  for i in 1..<queue.tasks.len:
    if queue.tasks[i].priority < queue.tasks[minIdx].priority:
      minIdx = i

  let next = queue.tasks[minIdx]
  queue.tasks.del(minIdx)
  some(next)
```

---

## Library Compilation Guide

### Compiling With --gc:none

Most standard library works with `--gc:none`, but avoid:
- `seq` methods that resize dynamically (allocate)
- GC-dependent code

**Safe patterns**:
```nim
# ✅ Safe - fixed size
var arr: array[100, int]

# ✅ Safe - pre-allocated
var seq: seq[int]
newSeq(seq, 10)  # Allocate once
seq[0] = 1       # Then use

# ❌ Unsafe - reallocates
var seq: seq[int]
seq.add(1)       # Reallocates on grow
seq.add(2)
```

### Arsenal Compilation

Arsenal is **pure Nim** and compiles cleanly:
```bash
nim c --gc:none --os:none arsenal.nim
```

Already tested and working in this codebase!

---

## Dependency Chain

```
Standard Library (always available)
├── strformat (strings)
├── sequtils (sequences)
├── algorithm (sorting, searching)
├── tables (hash tables)
├── deques (double-ended queues)
├── bitops (bit manipulation)
├── atomics (atomic ops)
└── strutils (string parsing)

Arsenal (provided, lock-free)
├── LockFreeQueue (enqueue/dequeue)
├── LockFreeStack (push/pop)
└── LockFreeCounter (atomic increment)

Custom Libraries (we write)
├── boot/ (bootloader interface)
├── mm/ (memory management)
├── kern/ (kernel core)
├── arch/ (architecture-specific)
├── drivers/ (device drivers)
├── fs/ (filesystem)
└── sync/ (synchronization)
```

---

## Library Usage by Component

### Memory Management
```nim
# mm/physical_manager.nim
- bitops: bitmap operations for frame allocation
- algorithm: sorting free lists

# mm/virtual_manager.nim
- tables: store address space info
- algorithm: search page structures

# mm/heap_allocator.nim
- strutils: parse alignment strings
- algorithm: search free blocks
```

### Scheduling
```nim
# sched/scheduler.nim
- arsenal/LockFreeQueue: ready queue
- algorithm: priority selection
- sequtils: filter by state

# sched/execution_model.nim
- tables: store characteristics
- strformat: stats formatting
```

### Process Management
```nim
# kern/process_manager.nim (future)
- tables: PID → Process mapping
- sequtils: filter by state
- deques: process queue
```

### I/O & Drivers
```nim
# drivers/serial/uart.nim (future)
- strutils: parse port addresses
- bitops: UART flags

# drivers/timer/pit.nim (future)
- strformat: debug output
```

### File System
```nim
# fs/vfs.nim (future)
- tables: dentry cache, inode cache
- algorithm: pathname lookup
- sequtils: directory listing
```

---

## Performance Considerations

### Arsenal Benefits (vs Spinlock)
```
Lock-free operations are:
- Faster on high contention (no spinning)
- Immune to priority inversion
- More scalable on many cores
- Better for interrupt-safe code

Use for:
✅ Ready queues
✅ Statistics counters
✅ Work-stealing queues
✅ Global task lists
```

### When Spinlocks are Still Needed
```
Use spinlock when:
✅ Critical section is tiny (<10 instructions)
✅ Low contention expected
✅ Can't use lock-free data structure

Examples:
- Per-task state changes
- Single counter increments
- Very small critical sections
```

### Allocator Choice by Phase
```
Phase 1: Static allocation only
- No heap allocations
- Everything on stack or data section

Phase 2+: Arsenal-backed allocator
- Lock-free counter for stats
- LockFreeQueue for ready queue
- Still using malloc/free for general use
```

---

## Future Library Candidates

### For Later Phases

1. **serialization** (nimble)
   - For ELF file loading
   - Binary format parsing

2. **bitset** (nimble)
   - Better than arrays for bitmaps
   - CPU affinity masks

3. **lru** (custom - not in nimble)
   - Implement ourselves for cache
   - File descriptor cache

4. **tinyvm** (nimble)
   - Bytecode VM for scripting
   - Shell implementation

---

## Best Practices

### 1. Explicit Imports
```nim
# ✅ Good - clear what we use
import strformat
import algorithm
import arsenal/lock_free_queue

# ❌ Avoid - too broad
import std
```

### 2. Minimal Standard Library
```nim
# ✅ Compile with minimal stdlib
nim c --os:none --minimalstdlib \
      --gc:none \
      kern/kernel_main.nim

# ✅ Only include what you use
import sequtils only filterIt
```

### 3. Document Dependencies
```nim
## Task Manager - LAYER 4
##
## Dependencies:
## - types (basic types)
## - spinlock (synchronization)
## - algorithm (priority selection)
## - arsenal/lock_free_queue (ready queue)
```

### 4. Avoid Runtime Dependencies
```nim
# ❌ Don't use
import httpclient  # Needs network
import asyncdispatch  # Needs scheduler
import os  # Needs OS calls

# ✅ Use
import strformat  # Pure string formatting
import algorithm  # Pure sorting
import arsenal  # Pure lock-free
```

---

## Testing Libraries

### What We Already Use
- ✅ `unittest` (from standard library)
- ✅ Custom framework in `tests/framework.nim`
- ✅ Mock objects for isolation

### Future Test Enhancements
```nim
# Add when convenient:
import criterion  # Benchmarking
import quicktest  # Property-based testing
```

---

## Summary: Library Strategy

1. **Phase 1**: Minimal use (strformat only)
2. **Phase 2**: Add Arsenal for scheduler
3. **Phase 3**: Add tables for caching
4. **Phase 4**: Add sequtils for process filtering
5. **Phase 5**: Add all advanced features

**Result**: Clean, efficient OS kernel built on proven libraries.

---

**Next**: Start Phase 1 implementation with this guide as reference!
