# Phase 1: Kernel Integration & Boot - Detailed Implementation Plan

**Phase 1 Goal**: Get kernel booting and running first idle task
**Estimated Time**: 2-3 weeks of focused development
**Total Lines**: ~1,200 Nim + ~400 x86_64 assembly

## Overview: What Phase 1 Achieves

```
Multiboot2 Bootloader
    ↓
Entry Point (boot.asm)
    ↓
Early Init (early_init.nim) - setup GDT, paging, BSP
    ↓
Kernel Main (kernel_main.nim) - initialize subsystems
    ↓
Scheduler Start - run idle task
    ↓
✓ First boot complete!
```

---

## Task-by-Task Breakdown

### TASK 1: Assembly Entry Point & Multiboot2 Header

**File**: `arch/x86_64/boot.asm`
**Language**: x86_64 Assembly (GNU AS syntax)
**Size**: ~150 lines
**Dependencies**: None (first code executed)

#### Subtasks:
1. **Multiboot2 header**
   - Magic number
   - Flags (page alignment, memory info)
   - Checksum calculation

2. **32-bit entry code**
   - Set up stack
   - Disable interrupts
   - Check Multiboot magic

3. **Long mode setup** (64-bit)
   - Load GDT
   - Setup paging
   - Enable 64-bit mode

4. **Call Nim kernel_main**
   - Pass boot info to Nim
   - Jump to kernel_main
   - Never return

**Test Strategy**: Verify assembly with objdump, test on QEMU

**Related Components**: Uses boot info from bootloader.nim

---

### TASK 2: Kernel Global Definitions

**File**: `kern/kernel.nim`
**Language**: Nim
**Size**: ~100 lines
**Dependencies**: None

#### Subtasks:
1. **Kernel constants**
   - Kernel base address
   - Kernel heap start/end
   - Kernel stack layout
   - Memory zones

2. **Global state**
   - Bootstrap processor info
   - CPU count
   - Memory size

3. **Initialization flags**
   - subsystemsInitialized
   - schedulerRunning
   - preemptionEnabled

**Code Example**:
```nim
const
  KERNEL_BASE* = 0xFFFF800000000000'u64
  KERNEL_HEAP_START* = 0xFFFF800010000000'u64
  KERNEL_HEAP_SIZE* = 512 * MiB

var
  gBootInfo*: BootInfo
  gKernelHeap*: HeapAllocator
  gScheduler*: SchedulerManager
```

---

### TASK 3: Early Initialization

**File**: `arch/x86_64/early_init.nim`
**Language**: Nim (with some unsafe operations)
**Size**: ~250 lines
**Dependencies**: kernel.nim, physical_manager.nim, virtual_manager.nim

#### Subtasks:
1. **Console output early**
   - VGA text mode setup (0xB8000)
   - Print function for debugging
   - Placeholder until real serial driver

2. **GDT setup**
   - Global Descriptor Table
   - Code/Data/TSS segments
   - Load GDT register

3. **Initial page tables**
   - Identity map first 4MB (for initial execution)
   - Map kernel to high address space
   - Setup page structures

4. **Extract boot info**
   - Parse Multiboot2 structures
   - Initialize physical memory manager
   - Initialize virtual memory manager

5. **BSP state initialization**
   - Setup interrupt stack
   - Mark BSP as initialized

**Nim Libraries**:
- Use `array` for GDT entries (no external deps)
- Use unsafe `cast` and pointers carefully
- Add `{.noinline.}` pragmas to prevent optimization issues

**Code Pattern**:
```nim
proc setupGdt*() =
  var gdt: array[8, GdtEntry]  # kernel code, data, user code, data, TSS, spare
  # Fill GDT entries
  let gdtAddr = cast[uint64](addr gdt[0])
  loadGdtRegister(gdtAddr, gdt.len)
```

---

### TASK 4: Kernel Main Entry Point

**File**: `kern/kernel_main.nim`
**Language**: Nim
**Size**: ~200 lines
**Dependencies**: boot.asm (calls this), early_init.nim, all subsystems

#### Subtasks:
1. **Verify boot state**
   - Check if called from boot.asm
   - Validate boot info magic
   - Check for required features (PAE, NX, etc)

2. **Initialize subsystems in order**
   ```
   1. Serial driver (for logging from here on)
   2. Console (real output)
   3. Interrupt system (need for timers)
   4. Per-CPU initialization
   5. Scheduler initialization
   6. Create idle task
   7. Start scheduler
   ```

3. **Per-CPU setup**
   - Detect CPU count from ACPI/boot info
   - Setup BSP structures
   - Setup per-CPU memory areas

4. **Scheduler handoff**
   - Create idle task
   - Start execution model scheduler
   - Enable interrupts
   - Jump to idle task

**Code Pattern**:
```nim
proc kernelMain*(bootInfoPtr: pointer) =
  # Called from boot.asm, running in 64-bit mode
  gBootInfo = parseBootInfo(bootInfoPtr)

  initConsole()
  kprint("NimixOS Kernel Boot\n")

  let result = gScheduler.scheduleWithModel()
  if result.isErr():
    kprint("Scheduler failed\n")
    while true: discard
```

---

### TASK 5: Console Driver (Early)

**File**: `core/console.nim`
**Language**: Nim
**Size**: ~150 lines
**Dependencies**: None (direct VGA/serial access)

#### Subtasks:
1. **VGA text mode output** (temporary)
   - Write to 0xB8000
   - Handle cursor position
   - Support colors

2. **Serial port UART** (real)
   - Detect serial ports
   - Initialize at 115200 baud
   - Send/receive characters

3. **Printf-style printing**
   - kprint() function
   - kprintln() function
   - Support basic formatting

**Nim Libraries**:
- Pure Nim (pointer access to hardware)
- Use inline I/O port reads/writes

**Code Pattern**:
```nim
proc outb(port: uint16, value: uint8) {.inline.} =
  asm """
    movb %0, %%al
    movw %1, %%dx
    outb %%al, %%dx
  """ : : "r"(value), "r"(port)

proc kprint*(msg: string) =
  for ch in msg:
    outb(0x3F8, uint8(ch))  # Send to COM1
```

---

### TASK 6: CPU Detection & Per-CPU State

**File**: `arch/x86_64/cpu.nim`
**Language**: Nim
**Size**: ~200 lines
**Dependencies**: kernel.nim, early_init.nim

#### Subtasks:
1. **CPUID probing**
   - Get CPU feature flags
   - Detect CPU count capability

2. **Boot info CPU count**
   - Extract from Multiboot2 or ACPI
   - Fallback to 1 if unavailable

3. **Per-CPU structure**
   - Per-CPU stack
   - Per-CPU task pointer
   - Per-CPU interrupt handling

4. **BSP (Bootstrap Processor) initialization**
   - Set current CPU = 0
   - Allocate BSP per-CPU data

**Nim Libraries**: Pure Nim (CPUID via inline assembly)

**Code Pattern**:
```nim
type
  PerCpuData* = object
    id*: int
    currentTask*: Task
    idleTask*: Task
    stack*: array[STACK_SIZE, byte]
    tssAddr*: uint64

var gPerCpuData*: array[MAX_CPUS, PerCpuData]
var gCpuCount*: int = 1
```

---

### TASK 7: Kernel Memory Layout & Initial Heap

**File**: `arch/x86_64/layout.nim`
**Language**: Nim
**Size**: ~150 lines
**Dependencies**: kernel.nim, early_init.nim

#### Subtasks:
1. **Define kernel memory regions**
   - Kernel code section (.text)
   - Kernel data section (.data/.bss)
   - Kernel heap region
   - Kernel stack region (per-CPU)

2. **Initial page table setup**
   - Map kernel sections
   - Setup demand paging for heap
   - Mark regions as kernel-only

3. **Heap initialization**
   - Reserve heap memory region
   - Initialize heap allocator
   - Test heap allocation

**Code Pattern**:
```nim
const
  KernelTextStart* = 0xFFFF800000000000'u64
  KernelDataStart* = 0xFFFF800000010000'u64
  KernelHeapStart* = 0xFFFF800010000000'u64
  KernelHeapSize* = 512 * MiB

var gKernelHeap*: HeapAllocator

proc initKernelMemory*() =
  # Map kernel sections to their addresses
  # Setup page table entries
  # Initialize heap in the reserved region
```

---

### TASK 8: Idle Task Creation

**File**: `kern/idle_task.nim`
**Language**: Nim
**Size**: ~100 lines
**Dependencies**: task_manager.nim, execution_model.nim

#### Subtasks:
1. **Idle task function**
   - Loop forever
   - Yield CPU repeatedly
   - Spin with HLT instruction when no work

2. **Create idle task per CPU**
   - Create in task manager
   - Register with execution model
   - Set priority to lowest

3. **Kernel thread infrastructure**
   - Infrastructure for kernel tasks
   - Stack allocation in kernel space
   - Entry point trampolines

**Code Pattern**:
```nim
proc idleTaskLoop*() {.noReturn.} =
  while true:
    # Check for work in scheduler
    let work = gScheduler.selectNext()
    if work.isSome():
      discard gScheduler.switchTo(nil, work.get())
    else:
      # No work - safe to halt
      hlt()

proc createIdleTask*(cpuId: int): Result[Task, KernelError] =
  # Create idle task for CPU
  # Set to lowest priority
  # Return task
```

---

### TASK 9: Interrupt Setup for Boot

**File**: `kern/boot_interrupts.nim`
**Language**: Nim
**Size**: ~100 lines
**Dependencies**: interrupts.nim, early_init.nim

#### Subtasks:
1. **IDT setup from boot**
   - Initialize IDT with kernel descriptor
   - Load default exception handlers
   - Install stub for timer interrupt

2. **Exception handling stubs**
   - Page fault handler stub
   - General protection fault stub
   - Double fault handler stub

3. **Enable exceptions**
   - Load IDT register
   - Enable interrupts (EFLAGS.IF)

**Note**: Full interrupt system already in `kern/interrupts.nim`, this just wires it for boot.

---

### TASK 10: Scheduler Boot Integration

**File**: `kern/boot_scheduler.nim`
**Language**: Nim
**Size**: ~150 lines
**Dependencies**: scheduler.nim, execution_model.nim, task_manager.nim

#### Subtasks:
1. **Initialize scheduler with execution model**
   - Determine which model to use (thread/fiber/green)
   - Create scheduler manager
   - Register with kernel

2. **Boot sequence**
   - Create idle task(s)
   - Add to scheduler ready queue
   - Select first task to run

3. **Handoff to scheduler**
   - Jump to first idle task context
   - Set up initial stack/registers
   - Enable preemption (if using threads)

**Code Pattern**:
```nim
proc bootScheduler*(model: ExecutionModel) =
  var taskMgr = newTaskManager(gKernelHeap, gVirtMemMgr)
  gScheduler = newSchedulerManager(taskMgr, gCpuCount, model)

  # Create idle task
  let idleResult = taskMgr.createTask("idle", idleTaskLoop)
  if idleResult.isErr():
    kprint("Failed to create idle task\n")
    return

  # Start scheduler
  gScheduler.scheduleWithModel()
```

---

## Nim Libraries to Use

### Already Available
- **arsenal** (provided): Lock-free data structures (arrays, queues)
  - Use `Arsenal.LockFreeQueue` for ready queue
  - Use `Arsenal.LockFreeStack` for work stealing

### From Nimble (recommended)
1. **strformat** - String formatting (already in std)
   - Use for kprintf-style functions

2. **sequtils** - Sequence utilities (already in std)
   - Use for array operations

3. **algorithm** - Sorting (already in std)
   - Use for priority queue in scheduler

### What NOT to use (in kernel)
- ❌ Threading libraries (we're writing scheduler)
- ❌ Async/await (we're writing async runtime)
- ❌ HTTP/network libraries
- ❌ GUI libraries
- ❌ Database libraries

---

## Implementation Order (Sequential)

```
Week 1:
├─ TASK 1: boot.asm entry point ................... ~150 lines asm
├─ TASK 2: kernel.nim globals ..................... ~100 lines nim
├─ TASK 3: early_init.nim (GDT, paging) .......... ~250 lines nim
└─ TASK 5: console.nim (VGA + serial) ............ ~150 lines nim

Week 2:
├─ TASK 6: cpu.nim (detection, per-cpu) ......... ~200 lines nim
├─ TASK 7: layout.nim (memory regions) ........... ~150 lines nim
├─ TASK 4: kernel_main.nim (orchestration) ....... ~200 lines nim
└─ TASK 8: idle_task.nim (kernel thread) ......... ~100 lines nim

Week 3:
├─ TASK 9: boot_interrupts.nim (IDT) ............. ~100 lines nim
└─ TASK 10: boot_scheduler.nim (scheduler init) .. ~150 lines nim

RESULT: Kernel boots to idle task!
```

---

## Integration with Existing Code

### Will Use (Existing Components)
- ✅ `boot/bootloader.nim` - Parse boot info
- ✅ `mm/physical_manager.nim` - Allocate frames
- ✅ `mm/virtual_manager.nim` - Setup paging
- ✅ `mm/heap_allocator.nim` - Kernel heap
- ✅ `kern/interrupts.nim` - IDT/exception setup
- ✅ `sched/execution_model.nim` - Choose execution model
- ✅ `sched/thread_model.nim` - Thread scheduling
- ✅ `sched/fiber_model.nim` - Fiber scheduling
- ✅ `sched/greenthread_model.nim` - Green thread scheduling
- ✅ `sched/task_manager.nim` - Task creation
- ✅ `sched/scheduler.nim` - Scheduling

### Will Create (New Components)
- 🆕 `arch/x86_64/boot.asm` - Assembly entry
- 🆕 `kern/kernel.nim` - Kernel globals
- 🆕 `arch/x86_64/early_init.nim` - Early boot
- 🆕 `core/console.nim` - Console output
- 🆕 `arch/x86_64/cpu.nim` - CPU detection
- 🆕 `arch/x86_64/layout.nim` - Memory layout
- 🆕 `kern/kernel_main.nim` - Kernel main
- 🆕 `kern/idle_task.nim` - Idle task
- 🆕 `kern/boot_interrupts.nim` - Boot IDT
- 🆕 `kern/boot_scheduler.nim` - Boot scheduler

---

## Testing Strategy for Phase 1

### Unit Tests
- Each boot component tested independently
- Memory layout verified
- CPU detection mocked

### Integration Tests
- Boot.asm → early_init.nim → kernel_main.nim pipeline
- Heap allocation during boot
- Scheduler initialization

### QEMU Tests
- Boot kernel with QEMU
- Check console output
- Verify CPU count detection
- Monitor task switching

### Test Execution (After Implementation)
```bash
# Build kernel
nim c --os:none --arch:amd64 --gc:none kern/kernel_main.nim

# Create ISO
grub-mkrescue -o kernel.iso boot/

# Run on QEMU
qemu-system-x86_64 -m 256 -cdrom kernel.iso -serial stdio
```

---

## Success Criteria for Phase 1

✅ **Kernel boots successfully**
- Boot.asm entry executes
- Transitions to 64-bit mode
- Calls kernel_main

✅ **Console output works**
- "NimixOS Kernel Boot" message appears
- Debug output during initialization
- No immediate crashes

✅ **Idle task running**
- One idle task per CPU
- Scheduler selects and runs idle task
- Infinite loop executing

✅ **No hangs or reboots**
- Graceful shutdown/halt
- Proper interrupt handling
- No triple faults

---

## Next Steps After Phase 1

Once Phase 1 is complete:
1. Add timer interrupt to enable preemption
2. Create multiple kernel tasks to test scheduling
3. Add basic system calls (first: write for debug)
4. Begin Phase 2 (I/O & Syscalls)

---

## Known Challenges & Solutions

### Challenge 1: Assembly to Nim calling convention
**Solution**: Use standard x86_64 System V ABI (rdi, rsi, rdx, rcx for args)

### Challenge 2: Stack alignment at boot
**Solution**: Ensure 16-byte alignment before call to kernel_main

### Challenge 3: Paging before Nim code can run
**Solution**: Early_init.nim sets up minimal paging, heap enables on-demand

### Challenge 4: Heap allocation needed before heap ready
**Solution**: Use static arrays for early structures (GDT, IDT, first page tables)

### Challenge 5: Circular dependency (heap needs VM, VM needs heap)
**Solution**: Bootstrap with static allocations, switch to dynamic after VM ready

---

**Ready to start with TASK 1 whenever you are!**
