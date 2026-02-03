# Phase 1: Library-First Implementation Guide

**Goal**: Leverage Arsenal and Nim stdlib to build Phase 1 efficiently
**Principle**: Use existing code, don't reinvent the wheel

---

## Strategic Library Usage for Phase 1

### What We Already Have Built ✅
```
✅ Physical Memory Manager (with bitmap allocator)
✅ Virtual Memory Manager (with page tables)
✅ Heap Allocator (with free-list)
✅ Interrupt System (IDT setup)
✅ Execution Models (thread, fiber, green thread)
✅ Task Manager
✅ Scheduler
✅ Arsenal library (lock-free structures)
```

These are NOT to be rewritten - just integrated.

---

## Phase 1 Tasks: Library-First Approach

### TASK 1.1: boot.asm Entry Point

**What to Write**: Assembly (unavoidable)
```asm
; This MUST be written in assembly
; No library can replace CPU mode switching
; But keep it minimal and focused

; Multiboot2 header (copy from spec)
; 32-bit protected mode setup (minimal)
; 64-bit long mode enable (standard procedure)
; Jump to Nim kernel_main (that's it)
```

**Research to Do**:
- [ ] Check if Nim has Multiboot2 header definition
- [ ] Look for existing boot.asm in other Nim OS projects
- [ ] Verify long mode setup procedure is standard

**Library Options**:
- ❌ Can't use libraries for assembly (CPU requirement)
- ✅ Can reuse standard x86_64 procedures from other projects

**Implementation Strategy**:
1. Search GitHub for "nim os kernel boot.asm"
2. Find working example
3. Adapt to our needs (minimal changes)
4. Test with QEMU

---

### TASK 1.2: kern/kernel.nim Globals

**What to Write**: Nim globals and configuration

**Don't Reinvent**:
- ✅ Use existing types from our built components
- ✅ Import from boot/bootloader.nim (already built)
- ✅ Use stdlib `const` and `var` declarations

```nim
import arch/common/boot_info
import mm/physical_manager
import mm/virtual_manager
import mm/heap_allocator
import sched/scheduler

const
  KERNEL_BASE* = 0xFFFF800000000000'u64
  # Use constants, don't calculate at runtime

var
  gBootInfo*: BootInfo  # Already defined in boot/bootloader.nim
  gKernelHeap*: HeapAllocator  # Already defined in mm/heap_allocator.nim
  gScheduler*: SchedulerManager  # Already defined in sched/scheduler.nim
```

**Library Usage**:
- ✅ Standard library `const`, `var`, `type`
- ✅ Reuse types from existing components

---

### TASK 1.3: arch/x86_64/early_init.nim

**What to Write**: Early initialization (GDT, paging, boot info parsing)

**Don't Reinvent**:

#### GDT Setup
```nim
# GDT structure already defined in x86_64 standards
# Don't reinvent - use standard layout

type
  GdtEntry* = object  # Use standard x86_64 definition
    limitLow*: uint16
    baseLow*: uint16
    baseMiddle*: uint8
    # ... standard fields

# Can find GDT definitions in:
# - https://github.com/nim-lang/Nim/tree/devel/lib
# - Other Nim OS projects
# - x86_64 architecture reference (copy standard layout)
```

**Reuse Existing**:
- ✅ Use `BootInfo` from `boot/bootloader.nim` (already built!)
- ✅ Use `PhysicalMemManager` from `mm/physical_manager.nim`
- ✅ Use `VirtualMemManager` from `mm/virtual_manager.nim`
- ✅ Parse boot info with existing `parseBootInfo()` function

#### Early Output
```nim
# For early console output before full driver
# Use simple VGA access - don't build full driver yet

proc writeVga*(text: cstring) =
  # Minimal VGA text mode output
  # This is temporary - real serial driver comes in TASK 1.5
  var ptr = cast[ptr uint16](0xB8000)
  for c in text:
    if c == '\0': break
    ptr[] = uint16(c) or 0x0F00  # White on black
    inc(ptr)
```

**Library Strategy**:
- ✅ Use existing memory manager types
- ✅ Use stdlib pointer/cast operations
- ✅ Minimal I/O code (temporary, will replace)

---

### TASK 1.4: kern/kernel_main.nim

**What to Write**: Orchestration that calls existing components

**This is mostly glue code - reuse everything!**

```nim
proc kernelMain*(bootInfoPtr: pointer) =
  # Step 1: Parse boot info (already built)
  gBootInfo = parseBootInfo(bootInfoPtr)

  # Step 2: Initialize console (will build in 1.5)
  initConsole()

  # Step 3: Use existing physical memory manager
  var physMgr = newPhysicalMemManager()
  physMgr.init(gBootInfo.memoryMap)

  # Step 4: Use existing virtual memory manager
  var virtMgr = newVirtualMemManager()
  virtMgr.init()

  # Step 5: Use existing interrupt system
  var intManager = newInterruptManager()
  discard intManager.initializeIdt(0x08)

  # Step 6: Use existing task manager
  var taskMgr = newTaskManager(gKernelHeap, virtMgr)

  # Step 7: Use existing scheduler with execution model
  let model = createThreadModelImpl()  # or fiber, green thread
  gScheduler = newSchedulerManager(taskMgr, gCpuCount, model)

  # Step 8: Boot scheduler (simple)
  gScheduler.scheduleWithModel()
```

**Don't Reinvent**:
- ✅ Use `newPhysicalMemManager()` - already built
- ✅ Use `newVirtualMemManager()` - already built
- ✅ Use `newInterruptManager()` - already built
- ✅ Use `newTaskManager()` - already built
- ✅ Use `createThreadModelImpl()` - already built
- ✅ Use `newSchedulerManager()` - already built

This task is 90% just wiring together existing components.

---

### TASK 1.5: core/console.nim

**What to Write**: Serial UART driver

**Library Options**:

#### Option A: Use Nim bindings if available
```bash
# Search nimble for existing UART implementations
nimble search uart
nimble search serial
nimble search driver
```

#### Option B: Minimal implementation
```nim
# Serial UART 16550 is standardized
# Can be implemented simply:

const COM1_PORT = 0x3F8

proc outb*(port: uint16, value: uint8) {.inline.} =
  # x86_64 I/O instruction via inline assembly
  asm """
    movb %0, %%al
    movw %1, %%dx
    outb %%al, %%dx
  """ : : "r"(value), "r"(port)

proc initUart*() =
  # Standard 16550 initialization
  # Simple sequence, ~10 lines of code
  # (well-documented in 16550 datasheet)
  outb(COM1_PORT + 1, 0)      # Disable interrupts
  outb(COM1_PORT + 3, 0x80)   # Set DLAB
  outb(COM1_PORT + 0, 1)      # Divisor low (115200 baud)
  outb(COM1_PORT + 1, 0)      # Divisor high
  outb(COM1_PORT + 3, 3)      # 8N1
  outb(COM1_PORT + 2, 0xC7)   # Enable FIFO
```

**Don't Reinvent**:
- ✅ Use standard 16550 initialization (copy from reference)
- ✅ Use inline assembly from stdlib
- ✅ Copy UART constants from spec (they're fixed)

**Research Sources**:
- [ ] OSDev.org - Serial driver guide (copy standard impl)
- [ ] 16550 UART datasheet (constants are standard)
- [ ] Other Nim projects for patterns
- [ ] Linux kernel source (serial driver for reference)

**Library Strategy**:
```nim
import strformat  # For kprintf-style output

proc kprint*(msg: string) =
  for c in msg:
    # Send to serial port
    outb(COM1_PORT, uint8(c))

    # Also to VGA for debugging
    # (temporary until full driver)

proc kprintf*(fmt: string, args: varargs[untyped]) =
  let msg = fmt(fmt, args)  # strformat from stdlib
  kprint(msg)
```

---

### TASK 1.6: arch/x86_64/cpu.nim

**What to Write**: CPU detection

**Don't Reinvent**:

#### CPUID Implementation
```nim
# CPUID is standardized x86_64 instruction
# Implementation is always similar

proc cpuid*(eax: uint32, ecx: uint32 = 0): tuple[eax, ebx, ecx, edx: uint32] =
  var eax = eax
  var ecx = ecx
  var ebx, edx: uint32

  asm """
    cpuid
  """ : "=a"(eax), "=b"(ebx), "=c"(ecx), "=d"(edx)
      : "a"(eax), "c"(ecx)

  (eax, ebx, ecx, edx)
```

#### CPU Count Detection
```nim
# Can use boot info provided by bootloader
# (already parsed in bootloader.nim)

proc detectCpuCount*(): int =
  # Option 1: From Multiboot2 info (easiest)
  if gBootInfo.cpuCount > 0:
    return gBootInfo.cpuCount

  # Option 2: From ACPI (complex, skip for now)
  # Option 3: Fallback to 1 CPU
  return 1
```

**Library Usage**:
- ✅ Use existing `gBootInfo` from Task 1.2
- ✅ Use stdlib `asm` for CPUID
- ✅ Use existing types from component modules

**Don't Reinvent**:
- ✅ CPUID is standardized (copy procedure)
- ✅ CPU count from boot info (already have it!)
- ✅ Per-CPU state from existing Task/Scheduler types

---

### TASK 1.7: arch/x86_64/layout.nim

**What to Write**: Memory layout definitions

**Don't Reinvent**:
- ✅ Use existing `HeapAllocator` from `mm/heap_allocator.nim`
- ✅ Use existing `VirtualMemManager` from `mm/virtual_manager.nim`
- ✅ Use existing page table structures

```nim
import mm/heap_allocator
import mm/virtual_manager

const
  KERNEL_BASE* = 0xFFFF800000000000'u64
  KERNEL_HEAP_START* = 0xFFFF800010000000'u64
  KERNEL_HEAP_SIZE* = 512 * 1024 * 1024  # Use stdlib math constants

# Reuse existing allocator - don't rewrite!
var gKernelHeap*: HeapAllocator

proc initKernelHeap*() =
  # Just initialize the existing allocator
  let buffer = allocateHeapBuffer(KERNEL_HEAP_SIZE)
  gKernelHeap.init(buffer, KERNEL_HEAP_SIZE)
```

**Library Strategy**:
- ✅ All data structures already exist
- ✅ This is pure configuration/orchestration
- ✅ No new allocators or managers needed

---

### TASK 1.8: kern/idle_task.nim

**What to Write**: Idle task loop

**Don't Reinvent**:
- ✅ Use existing `Task` type from `sched/task_manager.nim`
- ✅ Use existing `ExecutionModel` from `sched/execution_model.nim`
- ✅ Use existing scheduler operations

```nim
import sched/task_manager
import sched/execution_model

proc idleTaskLoop*() {.noReturn.} =
  while true:
    # Check for work via existing scheduler
    let next = gScheduler.selectNextUnit()

    if next.isSome():
      # Schedule next task using existing model
      discard gScheduler.model.switchTo(nil, next.get())
    else:
      # No work - safe halt via x86 instruction
      asm "hlt"

# Create idle task using existing task manager
proc createIdleTask*(cpuId: int): Task =
  let taskResult = gTaskMgr.createTask("idle", idleTaskLoop)
  return taskResult.value
```

**Library Strategy**:
- ✅ Use existing Task creation
- ✅ Use existing scheduler selection
- ✅ Only add HLT instruction (1 line of asm)

---

### TASK 1.9: kern/boot_interrupts.nim

**What to Write**: Boot IDT setup

**Don't Reinvent**:
- ✅ Use existing `InterruptManager` from `kern/interrupts.nim`
- ✅ Use existing exception handlers
- ✅ All IDT logic already exists!

```nim
import kern/interrupts

proc bootInterrupts*() =
  # Create manager (already built)
  let manager = newInterruptManager()

  # Initialize IDT (already implemented!)
  let result = manager.initializeIdt(0x08)
  if result.isErr():
    kprint("IDT init failed\n")
    return

  # Install default handlers (already implemented!)
  let handlerResult = manager.installDefaultHandlers()
  if handlerResult.isErr():
    kprint("Handler install failed\n")
    return

  kprint("Interrupts initialized\n")
```

**This task is mostly calling existing code!**

**Library Strategy**:
- ✅ 100% reuse of `InterruptManager`
- ✅ Just orchestration and error checking

---

### TASK 1.10: kern/boot_scheduler.nim

**What to Write**: Scheduler initialization

**Don't Reinvent**:
- ✅ Use existing `TaskManager` from `sched/task_manager.nim`
- ✅ Use existing `SchedulerManager` from `sched/scheduler.nim`
- ✅ Use existing execution models (thread/fiber/green thread)
- ✅ Use existing idle task from Task 1.8

```nim
import sched/task_manager
import sched/scheduler
import sched/execution_model
import sched/thread_model

proc bootScheduler*(model: ExecutionModel) =
  # Create task manager (existing)
  let taskMgr = newTaskManager(gKernelHeap, gVirtMemMgr)

  # Create scheduler with model (existing)
  gScheduler = newSchedulerManager(taskMgr, gCpuCount, model)

  # Create idle task for each CPU (existing)
  for cpuId in 0..<gCpuCount:
    let idleTask = createIdleTask(cpuId)
    discard gScheduler.enqueue(idleTask, cpuId)

  # Select first task and run (existing)
  gScheduler.scheduleWithModel()
```

**This is almost entirely glue code!**

**Library Strategy**:
- ✅ 95% reuse of existing scheduler/task code
- ✅ Choose execution model as parameter
- ✅ Start scheduling

---

### TASK 1.11: Test on QEMU

**What to Write**: Test harness

**Don't Reinvent**:
- ✅ Use existing test framework from `tests/framework.nim`
- ✅ Use existing boot simulation tests

```nim
# We already have boot simulation tests!
# Just run them on QEMU

# Build command
proc buildKernel*() =
  # Use Nim compiler (stdlib)
  # nim c --os:none --gc:none kern/kernel_main.nim

# Create ISO
proc createBootImage*() =
  # Use standard grub-mkrescue
  # grub-mkrescue -o kernel.iso boot/

# Run on QEMU
proc runQemu*() =
  # qemu-system-x86_64 -m 256 -cdrom kernel.iso -serial stdio
```

**Library Usage**:
- ✅ Already have comprehensive test suite
- ✅ Use existing boot simulation tests
- ✅ Standard tools (QEMU, grub-mkrescue)

---

## Summary: Library-First Phase 1

| Task | Lines | Reuse | New Code |
|------|-------|-------|----------|
| 1.1 boot.asm | 150 asm | Boot header (copy spec) | Long mode setup |
| 1.2 kernel.nim | 100 | All types | Just `const`/`var` |
| 1.3 early_init.nim | 250 | All managers | GDT, paging setup |
| 1.4 kernel_main.nim | 200 | 100% reuse | Just orchestration |
| 1.5 console.nim | 150 | Serial spec (standard) | ~20 lines unique |
| 1.6 cpu.nim | 200 | Boot info | CPUID procedure |
| 1.7 layout.nim | 150 | All allocators | Memory constants |
| 1.8 idle_task.nim | 100 | Task manager | Idle loop only |
| 1.9 boot_interrupts.nim | 100 | InterruptManager | Just calls |
| 1.10 boot_scheduler.nim | 150 | Scheduler/Task | Just orchestration |
| 1.11 Testing | - | Existing tests | Just run |
| **TOTAL** | ~1,350 | ~1,050 (78%) | ~300 (22%) |

**Only 22% truly new code - 78% is library reuse!**

---

## Libraries Available During Phase 1

### Arsenal (Provided)
```nim
import arsenal/lock_free_queue
# Already using in scheduler ready queue
```

### Nim Standard Library (Safe with --gc:none)
```nim
import strformat           # kprintf formatting
import bitops             # Bit manipulation
import algorithm          # Sorting (if needed)
import sequtils           # Sequence utilities (if needed)
```

### What We Built (Reuse 100%)
```nim
import boot/bootloader              # parseBootInfo()
import mm/physical_manager          # PhysicalMemManager
import mm/virtual_manager           # VirtualMemManager
import mm/heap_allocator            # HeapAllocator
import kern/interrupts              # InterruptManager
import sched/execution_model        # ExecutionModel trait
import sched/thread_model           # Thread model
import sched/fiber_model            # Fiber model
import sched/greenthread_model      # Green thread model
import sched/task_manager           # TaskManager
import sched/scheduler              # SchedulerManager
import tests/framework              # Test utilities
```

---

## Getting Code (Don't Write From Scratch)

### For Each Task, Search:

1. **GitHub OSDev Repos**
   ```bash
   # Search for "Nim os kernel" + task name
   # Find working examples
   # Adapt minimal, don't rewrite
   ```

2. **OSDev.org Wiki**
   - Multiboot2 header specification
   - x86_64 boot process
   - 16550 UART driver
   - GDT setup procedure
   - Copy standard procedures

3. **Linux Kernel Source**
   ```bash
   # For reference implementations
   # Serial driver: drivers/tty/serial/8250/
   # CPUID: arch/x86/cpufeature.c
   # Don't copy directly, understand and adapt
   ```

4. **Nim Community**
   ```bash
   nimble search uart
   nimble search serial
   nimble search cpuid
   # Find and reuse if available
   ```

---

## Implementation Philosophy for Phase 1

✅ **DO THIS**:
- Use existing components we built
- Reuse standard procedures (GDT, UART, CPUID)
- Copy working code from OSDev/Linux with attribution
- Leverage Arsenal and stdlib
- Focus on orchestration and integration

❌ **DON'T DO THIS**:
- Rewrite GDT setup (use standard layout)
- Reinvent UART driver (use 16550 standard)
- Create new CPUID implementation (one standard way)
- Write custom allocators (we have HeapAllocator)
- Create memory managers (we have PhysicalMemManager + VirtualMemManager)

---

## Result: Efficient Phase 1

By leveraging libraries and existing code:
- ✅ 78% code reuse
- ✅ Only 22% truly new code
- ✅ Fast implementation (2-3 weeks estimated)
- ✅ Low bug risk (reusing tested code)
- ✅ High maintainability (understood, documented code)

**Ready to start Phase 1 with library-first approach!** 🚀
