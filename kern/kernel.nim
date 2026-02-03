# SPDX-License-Identifier: GPL-2.0
## Kernel Globals & Constants - LAYER 1
##
## Common definitions used throughout the kernel
## Kernel memory layout, configuration constants, utility types
##
## This module defines the "shape" of the kernel:
## - Where kernel code runs (address space)
## - How much memory to reserve
## - Default timeouts and limits
## - Version information
##
## These are mostly constants that don't change after boot,
## plus some global state initialized by kernel_main.nim

import ../core/types

# ═══════════════════════════════════════════════════════════════════════════
# Kernel Version & Identification
# ═══════════════════════════════════════════════════════════════════════════

const
  KERNEL_NAME* = "NimixOS"
  KERNEL_VERSION_MAJOR* = 0
  KERNEL_VERSION_MINOR* = 1
  KERNEL_VERSION_PATCH* = 0
  KERNEL_VERSION* = "0.1.0-alpha"
  KERNEL_CODENAME* = "Innovation First"

  # Build information
  KERNEL_ARCH* = "x86_64"
  KERNEL_PLATFORM* = "PC/BIOS"

proc getKernelVersion*(): string =
  ## Get kernel version string
  &"{KERNEL_NAME} {KERNEL_VERSION} ({KERNEL_ARCH})"

# ═══════════════════════════════════════════════════════════════════════════
# Kernel Address Space Layout (x86_64)
# ═══════════════════════════════════════════════════════════════════════════

## Kernel runs in high virtual address space to leave low addresses for user
## Standard x86_64 layout with sign-extended addresses
##
## Virtual Address Space:
## ┌─────────────────────────────────────────────────────────────┐
## │ User space: 0x0000000000000000 - 0x00007FFFFFFFFFFF        │
## │             (128 TB)                                        │
## ├─────────────────────────────────────────────────────────────┤
## │ Kernel space: 0xFFFF800000000000 - 0xFFFFFFFFFFFFFFFF      │
## │              (128 TB)                                       │
## └─────────────────────────────────────────────────────────────┘

const
  ## Kernel base address (high canonical)
  KERNEL_BASE* = 0xFFFF800000000000'u64

  ## Kernel code section
  KERNEL_TEXT_START* = 0xFFFF800000000000'u64
  KERNEL_TEXT_SIZE* = 16 * MiB

  ## Kernel data section (.data, .bss)
  KERNEL_DATA_START* = 0xFFFF800001000000'u64
  KERNEL_DATA_SIZE* = 16 * MiB

  ## Kernel heap (dynamic allocations)
  KERNEL_HEAP_START* = 0xFFFF800010000000'u64
  KERNEL_HEAP_MAX_SIZE* = 512 * MiB  # Can be configured at boot

  ## Per-CPU kernel stacks
  KERNEL_STACK_START* = 0xFFFF800020000000'u64
  KERNEL_STACK_SIZE* = 16 * KiB  # Per CPU
  KERNEL_STACK_TOTAL* = 512 * MiB  # 32K CPUs max

  ## Kernel structures and metadata
  KERNEL_META_START* = 0xFFFF800030000000'u64
  KERNEL_META_SIZE* = 64 * MiB

  ## Physical memory mapped area (if needed)
  KERNEL_PHYS_MAP_START* = 0xFFFF800040000000'u64
  KERNEL_PHYS_MAP_SIZE* = 512 * GiB  # Map all physical memory here

  ## Reserved for future kernel use
  KERNEL_RESERVED_START* = 0xFFFF900000000000'u64

proc getKernelLayout*(): string =
  ## Get formatted kernel memory layout
  var result = "Kernel Memory Layout (x86_64):\n"
  result &= fmt"  Text:     {KERNEL_TEXT_START:016X} - {KERNEL_TEXT_START + KERNEL_TEXT_SIZE:016X}\n"
  result &= fmt"  Data:     {KERNEL_DATA_START:016X} - {KERNEL_DATA_START + KERNEL_DATA_SIZE:016X}\n"
  result &= fmt"  Heap:     {KERNEL_HEAP_START:016X} - {KERNEL_HEAP_START + KERNEL_HEAP_MAX_SIZE:016X}\n"
  result &= fmt"  Stacks:   {KERNEL_STACK_START:016X} - {KERNEL_STACK_START + KERNEL_STACK_TOTAL:016X}\n"
  result &= fmt"  Phys Map: {KERNEL_PHYS_MAP_START:016X} - {KERNEL_PHYS_MAP_START + KERNEL_PHYS_MAP_SIZE:016X}\n"
  result

# ═══════════════════════════════════════════════════════════════════════════
# User Address Space
# ═══════════════════════════════════════════════════════════════════════════

const
  ## User space runs in low virtual addresses
  USER_SPACE_START* = 0x0000000000000000'u64
  USER_SPACE_END* = 0x00007FFFFFFFFFFF'u64
  USER_SPACE_SIZE* = USER_SPACE_END - USER_SPACE_START + 1

  ## Default user stack location and size
  USER_STACK_START* = 0x00007FFFFFFFF000'u64  # Just below USER_SPACE_END
  USER_STACK_MAX_SIZE* = 8 * MiB

# ═══════════════════════════════════════════════════════════════════════════
# Kernel Timing & Timers
# ═══════════════════════════════════════════════════════════════════════════

const
  ## System timer frequency (Hz)
  ## Higher = more precise scheduling, higher overhead
  KERNEL_TIMER_HZ* = 1000'u32  # 1000 HZ = 1ms time slice

  ## Timer period in nanoseconds
  KERNEL_TIMER_NS* = 1_000_000_000 / KERNEL_TIMER_HZ

  ## Default time slice for round-robin scheduling (in timer ticks)
  DEFAULT_TIME_SLICE* = 10'u64  # 10ms

  ## Scheduler reschedule frequency
  SCHEDULER_TICK_NS* = 1_000_000  # Reschedule every 1ms

# ═══════════════════════════════════════════════════════════════════════════
# Process/Task Limits
# ═══════════════════════════════════════════════════════════════════════════

const
  ## Maximum number of processes the kernel can manage
  MAX_PROCESSES* = 65536'u32

  ## Maximum number of CPUs (cores) supported
  MAX_CPUS* = 256'u32

  ## Maximum number of file descriptors per process
  MAX_FDS_PER_PROCESS* = 1024'u32

  ## Maximum number of threads per process
  MAX_THREADS_PER_PROCESS* = 8192'u32

# ═══════════════════════════════════════════════════════════════════════════
# Memory & Page Configuration
# ═══════════════════════════════════════════════════════════════════════════

const
  ## Standard page size (4KB)
  PAGE_SIZE* = 4096'u64

  ## Large page size (2MB - x86_64 supports 2MB and 1GB huge pages)
  HUGE_PAGE_2MB* = 2 * MiB

  ## Huge page size (1GB)
  HUGE_PAGE_1GB* = 1 * GiB

  ## Number of page levels for x86_64 (PML4/PDPT/PD/PT = 4 levels)
  PAGE_LEVELS* = 4'u32

  ## Bits per page level
  PAGE_LEVEL_BITS* = 9'u32  # 2^9 = 512 entries per level

# ═══════════════════════════════════════════════════════════════════════════
# Cache & Performance Tuning
# ═══════════════════════════════════════════════════════════════════════════

const
  ## L1 cache line size (typical x86_64)
  CACHE_LINE_SIZE* = 64'u32

  ## TLB entry size (affects page allocation strategy)
  TLB_ENTRY_SIZE* = 64'u32  # x86_64 has ~64 DTLB and ITLB entries

# ═══════════════════════════════════════════════════════════════════════════
# System Limits & Defaults
# ═══════════════════════════════════════════════════════════════════════════

const
  ## Default stack size for kernel threads
  DEFAULT_KERNEL_STACK_SIZE* = 16 * KiB

  ## Default stack size for user processes
  DEFAULT_USER_STACK_SIZE* = 8 * MiB

  ## Maximum number of open files system-wide
  MAX_OPEN_FILES* = 8192'u32

  ## Default interrupt stack size (IST stack for exceptions)
  DEFAULT_IST_STACK_SIZE* = 8 * KiB

# ═══════════════════════════════════════════════════════════════════════════
# Debug & Logging Configuration
# ═══════════════════════════════════════════════════════════════════════════

const
  ## Debug level (0 = no debug, 3 = verbose)
  DEBUG_LEVEL* {.strdefine.} = "1"

  ## Enable memory tracking/leak detection in debug mode
  DEBUG_MEMORY* {.booldefine.} = false

  ## Enable scheduler tracing
  DEBUG_SCHEDULER* {.booldefine.} = false

  ## Enable interrupt tracing
  DEBUG_INTERRUPTS* {.booldefine.} = false

# ═══════════════════════════════════════════════════════════════════════════
# Kernel Configuration Defaults
# ═══════════════════════════════════════════════════════════════════════════

proc getDefaultKernelSettings*(): string =
  ## Get formatted kernel settings
  var result = "Kernel Settings:\n"
  result &= fmt"  Timer: {KERNEL_TIMER_HZ} Hz ({KERNEL_TIMER_NS} ns/tick)\n"
  result &= fmt"  Time Slice: {DEFAULT_TIME_SLICE} ticks\n"
  result &= fmt"  Max Processes: {MAX_PROCESSES}\n"
  result &= fmt"  Max CPUs: {MAX_CPUS}\n"
  result &= fmt"  Page Size: {PAGE_SIZE} bytes\n"
  result

# ═══════════════════════════════════════════════════════════════════════════
# Magic Numbers & Signatures
# ═══════════════════════════════════════════════════════════════════════════

## Used for validation and debugging

const
  ## Magic number for kernel heap headers
  KERNEL_HEAP_MAGIC* = 0x4B45524E'u32  # "KERN"

  ## Magic number for kernel stack guards
  KERNEL_STACK_GUARD_MAGIC* = 0x53544143'u32  # "STAC"

  ## Magic number for kernel structures
  KERNEL_STRUCT_MAGIC* = 0x4B424F58'u32  # "KBOX"

# ═══════════════════════════════════════════════════════════════════════════
# Kernel Behavior Flags
# ═══════════════════════════════════════════════════════════════════════════

type
  KernelBehavior* = enum
    ## Flags controlling kernel behavior
    kbStrictMemoryCheck   ## Enable strict memory checking
    kbEnablePreemption    ## Enable preemptive scheduling
    kbEnablePageColoring  ## Use page coloring to reduce cache conflicts
    kbEnableSpectreFilter ## Enable Spectre mitigation
    kbEnableMeltdownFilter ## Enable Meltdown mitigation

# ═══════════════════════════════════════════════════════════════════════════
# Forward Declarations
# ═══════════════════════════════════════════════════════════════════════════

## The following are declared in kernel_main.nim and other modules
## They're listed here for reference

# Global kernel state (in kernel_main.nim):
#   var gBootInfo*: BootInfo
#   var gKernelConfig*: KernelConfig
#   var gPhysMemMgr*: PhysicalMemManager
#   var gVirtMemMgr*: VirtualMemManager
#   var gKernelHeap*: HeapAllocator
#   var gInterruptMgr*: InterruptManager
#   var gTaskMgr*: TaskManager
#   var gScheduler*: SchedulerManager

# ═══════════════════════════════════════════════════════════════════════════
# Utility Functions
# ═══════════════════════════════════════════════════════════════════════════

proc isKernelAddress*(addr: uint64): bool {.inline.} =
  ## Check if address is in kernel space
  (addr and 0xFFFF800000000000'u64) == 0xFFFF800000000000'u64

proc isUserAddress*(addr: uint64): bool {.inline.} =
  ## Check if address is in user space
  not isKernelAddress(addr)

proc pageAlign*(addr: uint64): uint64 {.inline.} =
  ## Align address to next page boundary
  (addr + PAGE_SIZE - 1) and not (PAGE_SIZE - 1)

proc isPageAligned*(addr: uint64): bool {.inline.} =
  ## Check if address is page-aligned
  (addr mod PAGE_SIZE) == 0

proc getPageNumber*(addr: uint64): uint64 {.inline.} =
  ## Get page number from address
  addr div PAGE_SIZE

# ═══════════════════════════════════════════════════════════════════════════
# Documentation & Philosophy
# ═══════════════════════════════════════════════════════════════════════════

## This module defines the kernel's static configuration.
##
## WHY SEPARATE MODULE?
##
## 1. Central reference for all kernel constants
## 2. Easy to find and modify kernel-wide settings
## 3. Can be referenced without circular dependencies
## 4. Clear documentation of kernel layout and assumptions
##
## LAYOUT PHILOSOPHY:
##
## The kernel runs in high virtual addresses (0xFFFF8000...) to:
## - Leave low addresses (0x0000000...) for user programs
## - Make exploits harder (user can't easily spoof kernel pointers)
## - Follow x86_64 canonical form requirements
## - Leave room for dynamic user address space growth
##
## CONFIGURATION:
##
## These constants can be:
## - Modified for different build variants (embedded, RTOS, etc.)
## - Passed as compile-time options (nim -d:DEBUG_LEVEL=3)
## - Used to generate different kernel configurations
##
## FUTURE:
##
## Once kernel boots, these can seed a runtime configuration
## that can be modified (within limits) by admin tools.
