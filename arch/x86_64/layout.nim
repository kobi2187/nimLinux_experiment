# SPDX-License-Identifier: GPL-2.0
## Kernel Memory Layout - LAYER 2 (x86_64 specific)
##
## Defines and initializes kernel memory regions
## Maps kernel space to physical memory
## Sets up early heap in reserved area
##
## This module bridges boot-time memory allocation with
## runtime memory managers (physical, virtual, heap)

import ../kern/kernel
import ../core/types
import ../core/console

# ═══════════════════════════════════════════════════════════════════════════
# Memory Region Information
# ═══════════════════════════════════════════════════════════════════════════

type
  MemoryRegion* = object
    ## Physical memory region
    name*: string
    physStart*: PhysAddr
    physEnd*: PhysAddr
    virtStart*: VirtAddr
    virtEnd*: VirtAddr
    flags*: uint32  # Page flags (present, writable, etc.)
    size*: uint64

# ═══════════════════════════════════════════════════════════════════════════
# Kernel Memory Regions
# ═══════════════════════════════════════════════════════════════════════════

var gMemoryRegions*: seq[MemoryRegion] = @[]

proc registerMemoryRegion*(
    name: string,
    physStart: PhysAddr,
    physEnd: PhysAddr,
    virtStart: VirtAddr,
    size: uint64,
    flags: uint32) =
  ## Register a kernel memory region
  let region = MemoryRegion(
    name: name,
    physStart: physStart,
    physEnd: physEnd,
    virtStart: virtStart,
    virtEnd: virtStart + size,
    flags: flags,
    size: size
  )
  gMemoryRegions.add(region)

# ═══════════════════════════════════════════════════════════════════════════
# Early Heap Buffer - Pre-allocated during boot
# ═══════════════════════════════════════════════════════════════════════════

## Early heap buffer is statically allocated
## Used before full heap manager is initialized
## Located in kernel .bss section

const
  EARLY_HEAP_SIZE* = 4 * MiB

var
  gEarlyHeapBuffer*: array[EARLY_HEAP_SIZE, uint8]
  gEarlyHeapCurrent*: uint64 = 0

proc allocateFromEarlyHeap*(size: uint64, alignment: uint64 = 8): pointer =
  ## Allocate from early heap (before full heap manager)
  ## Used during boot for temporary allocations
  ##
  ## Note: Fragmentation is not handled - use sparingly
  ## For Phase 1, only used for minimal boot-time structures

  # Align current position
  var current = gEarlyHeapCurrent
  let alignMask = alignment - 1
  if (current and alignMask) != 0:
    current = (current + alignMask) and not alignMask

  # Check bounds
  if current + size > EARLY_HEAP_SIZE:
    return nil  # Out of early heap

  # Allocate
  let ptr = addr gEarlyHeapBuffer[current]
  gEarlyHeapCurrent = current + size

  cast[pointer](ptr)

proc getEarlyHeapUsage*(): uint64 =
  ## Get current early heap usage
  gEarlyHeapCurrent

proc resetEarlyHeap*() =
  ## Reset early heap (use after switching to main heap)
  gEarlyHeapCurrent = 0

# ═══════════════════════════════════════════════════════════════════════════
# Kernel Layout Initialization
# ═══════════════════════════════════════════════════════════════════════════

proc initializeMemoryLayout*() =
  ## Initialize kernel memory layout
  ## Called from kernel_main during boot
  ##
  ## This registers all kernel regions but doesn't physically
  ## map them - that's done by virtual_manager.nim

  kprintln("Initializing kernel memory layout...")

  # Kernel text section
  registerMemoryRegion(
    "Kernel Text",
    PhysAddr(0),  # Physical address determined by linker
    PhysAddr(KERNEL_TEXT_SIZE),
    KERNEL_TEXT_START,
    KERNEL_TEXT_SIZE,
    0x01  # Present
  )

  # Kernel data section
  registerMemoryRegion(
    "Kernel Data",
    PhysAddr(KERNEL_TEXT_SIZE),
    PhysAddr(KERNEL_TEXT_SIZE + KERNEL_DATA_SIZE),
    KERNEL_DATA_START,
    KERNEL_DATA_SIZE,
    0x03  # Present + Writable
  )

  # Kernel heap
  registerMemoryRegion(
    "Kernel Heap",
    PhysAddr(KERNEL_TEXT_SIZE + KERNEL_DATA_SIZE),
    PhysAddr(KERNEL_TEXT_SIZE + KERNEL_DATA_SIZE + KERNEL_HEAP_MAX_SIZE),
    KERNEL_HEAP_START,
    KERNEL_HEAP_MAX_SIZE,
    0x03  # Present + Writable
  )

  # Kernel stacks
  registerMemoryRegion(
    "Kernel Stacks",
    PhysAddr(0),  # Allocated dynamically
    PhysAddr(0),
    KERNEL_STACK_START,
    KERNEL_STACK_TOTAL,
    0x03  # Present + Writable
  )

  # Kernel metadata
  registerMemoryRegion(
    "Kernel Metadata",
    PhysAddr(0),  # Allocated dynamically
    PhysAddr(0),
    KERNEL_META_START,
    KERNEL_META_SIZE,
    0x03  # Present + Writable
  )

  kprintln(fmt"Registered {gMemoryRegions.len} memory regions")

proc printMemoryLayout*() =
  ## Print kernel memory layout
  kprintln("")
  kprintln("Kernel Memory Layout:")
  for region in gMemoryRegions:
    let sizeKB = region.size div 1024
    let sizeMB = if region.size >= MiB: region.size div MiB else: 0
    let sizeStr = if sizeMB > 0: fmt"{sizeMB}MB" else: fmt"{sizeKB}KB"
    kprintln(fmt"  {region.name:20} {region.virtStart:016X} size: {sizeStr}")
  kprintln("")

# ═══════════════════════════════════════════════════════════════════════════
# Address Space Mapping Functions
# ═══════════════════════════════════════════════════════════════════════════

proc physToVirt*(phys: PhysAddr): VirtAddr =
  ## Convert physical address to kernel virtual address
  ## Simple identity mapping for kernel space
  KERNEL_BASE + uint64(phys)

proc virtToPhys*(virt: VirtAddr): PhysAddr =
  ## Convert kernel virtual address to physical address
  ## Simple identity mapping for kernel space
  PhysAddr(virt - KERNEL_BASE)

proc isKernelAddress*(addr: uint64): bool {.inline.} =
  ## Check if address is in kernel space
  (addr and 0xFFFF800000000000'u64) == 0xFFFF800000000000'u64

proc isPhysicalAddress*(addr: uint64): bool {.inline.} =
  ## Check if address is physical (not kernel virtual)
  not isKernelAddress(addr)

# ═══════════════════════════════════════════════════════════════════════════
# Memory Map Information
# ═══════════════════════════════════════════════════════════════════════════

proc getMemoryRegion*(name: string): Option[MemoryRegion] =
  ## Find memory region by name
  for region in gMemoryRegions:
    if region.name == name:
      return some(region)
  none(MemoryRegion)

proc getMemoryRegionByVirtAddr*(addr: VirtAddr): Option[MemoryRegion] =
  ## Find memory region containing virtual address
  for region in gMemoryRegions:
    if addr >= region.virtStart and addr < region.virtEnd:
      return some(region)
  none(MemoryRegion)

proc getMemoryRegionByPhysAddr*(addr: PhysAddr): Option[MemoryRegion] =
  ## Find memory region containing physical address
  for region in gMemoryRegions:
    if uint64(addr) >= uint64(region.physStart) and uint64(addr) < uint64(region.physEnd):
      return some(region)
  none(MemoryRegion)

# ═══════════════════════════════════════════════════════════════════════════
# Memory Layout Statistics
# ═══════════════════════════════════════════════════════════════════════════

proc getTotalKernelMemory*(): uint64 =
  ## Get total kernel memory allocated
  var total: uint64 = 0
  for region in gMemoryRegions:
    total += region.size
  total

proc getMemoryLayoutStats*(): string =
  ## Get formatted memory layout statistics
  let total = getTotalKernelMemory()
  let totalMB = total div MiB
  let earlyHeapUsage = getEarlyHeapUsage()
  let earlyHeapUsageMB = earlyHeapUsage div MiB

  var result = "Memory Layout Statistics:\n"
  result &= fmt"  Total Kernel Memory: {totalMB} MB\n"
  result &= fmt"  Early Heap Usage: {earlyHeapUsageMB} MB / {EARLY_HEAP_SIZE div MiB} MB\n"
  result &= fmt"  Registered Regions: {gMemoryRegions.len}\n"

  result

# ═══════════════════════════════════════════════════════════════════════════
# Notes on Architecture
# ═══════════════════════════════════════════════════════════════════════════

## MEMORY LAYOUT PHILOSOPHY:
##
## This module defines and initializes the kernel memory layout.
## It doesn't actually MAP memory - that's virtual_manager.nim's job.
## This just REGISTERS what exists and where it goes.
##
## EARLY HEAP:
## - Statically allocated (4MB in .bss)
## - Used before main heap manager initializes
## - Minimal, temporary allocations only
## - Fragmentation not handled (acceptable for boot)
##
## MEMORY REGIONS:
## - Text (code): 16 MB, read-only
## - Data (.data/.bss): 16 MB, read-write
## - Heap: 512 MB, read-write (dynamic)
## - Stacks: 512 MB total, read-write (per-CPU 16KB)
## - Metadata: 64 MB, read-write
##
## ADDRESS MAPPING:
## - Identity mapping for kernel space
## - Physical addr X -> Virtual addr (KERNEL_BASE + X)
## - Defined in kern/kernel.nim
##
## NEXT STEPS:
## - Virtual memory manager does actual paging
## - Heap allocator manages heap region
## - Per-CPU stacks allocated from stack region
## - Metadata used for data structures
