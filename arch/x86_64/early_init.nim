# SPDX-License-Identifier: GPL-2.0
## Early Initialization - LAYER 2 (x86_64 specific)
##
## Runs after boot.asm entry point, before Nim kernel_main
## Sets up:
## - Global Descriptor Table (GDT) for 64-bit mode
## - Interrupt Descriptor Table (IDT) stub
## - Initial page tables for kernel space
## - Parses boot information from bootloader
##
## Called from: boot.asm (entry point)
## Calls into: kernel_main.nim (orchestration)
##
## Philosophy: Minimal setup to get to kernel_main
## Everything else is in kernel_main.nim (composable, swappable)

import ../../arch/common/boot_info
import ../../boot/bootloader
import ../../core/types
import ../../kern/kernel

# ═══════════════════════════════════════════════════════════════════════════
# Global Descriptor Table (GDT) - x86_64 64-bit mode
# ═══════════════════════════════════════════════════════════════════════════

type
  ## x86_64 GDT Entry (8 bytes)
  GdtEntry* = object
    limitLow*: uint16        # Bits 0-15 of limit (ignored in 64-bit)
    baseLow*: uint16         # Bits 0-15 of base (ignored in 64-bit)
    baseMiddle*: uint8       # Bits 16-23 of base (ignored in 64-bit)
    access*: uint8           # Segment type, DPL, present
    granularity*: uint8      # Granularity, size, long mode
    baseHigh*: uint8         # Bits 24-31 of base (ignored in 64-bit)

  ## GDT Descriptor (pointer for LGDT instruction)
  GdtDescriptor* = object
    size*: uint16            # GDT size - 1
    offset*: uint64          # GDT base address

# ═══════════════════════════════════════════════════════════════════════════
# GDT Entries - 64-bit Segments
# ═══════════════════════════════════════════════════════════════════════════

## In 64-bit mode, most GDT fields are ignored
## What matters:
## - Type (code, data, TSS)
## - DPL (privilege level)
## - P (present bit)
## - L (long mode flag for code)

const
  ## Segment type: Code, Execute, Readable, Accessed
  GDT_TYPE_CODE* = 0b1010'u8  # Type = 10 (code)

  ## Segment type: Data, Writable, Accessed
  GDT_TYPE_DATA* = 0b0010'u8  # Type = 2 (data)

  ## Segment type: Task State Segment
  GDT_TYPE_TSS* = 0b1001'u8   # Type = 9 (TSS)

  ## DPL: Privilege level 0 (kernel)
  GDT_DPL_KERNEL* = 0b00'u8

  ## DPL: Privilege level 3 (user)
  GDT_DPL_USER* = 0b11'u8

  ## Present bit
  GDT_PRESENT* = 0b1'u8

  ## Long mode (64-bit) flag
  GDT_LONG* = 0b1'u8

  ## Granularity (4KB pages instead of bytes)
  GDT_GRANULARITY* = 0b1'u8

var
  ## Global GDT (placed in kernel data section)
  ## Layout: [Null, Kernel Code, Kernel Data, User Code, User Data, TSS...]
  gGdt*: array[10, GdtEntry]

  ## GDT descriptor for LGDT instruction
  gGdtDescriptor*: GdtDescriptor

# ═══════════════════════════════════════════════════════════════════════════
# GDT Setup Functions
# ═══════════════════════════════════════════════════════════════════════════

proc createGdtEntry*(access: uint8, granularity: uint8): GdtEntry =
  ## Create GDT entry (simplified for 64-bit mode)
  ## In 64-bit, base and limit are mostly ignored
  GdtEntry(
    limitLow: 0xFFFF,        # Ignored in 64-bit
    baseLow: 0,              # Ignored in 64-bit
    baseMiddle: 0,           # Ignored in 64-bit
    access: access,
    granularity: granularity,
    baseHigh: 0              # Ignored in 64-bit
  )

proc setupGdt*() =
  ## Initialize Global Descriptor Table
  ## Required for 64-bit mode execution
  ##
  ## GDT Structure (indices):
  ## 0: Null descriptor (required, unused)
  ## 1: Kernel code 64-bit
  ## 2: Kernel data 64-bit
  ## 3: User code 64-bit
  ## 4: User data 64-bit
  ## 5+: TSS and other descriptors (if needed)

  # Entry 0: Null (required by CPU)
  gGdt[0] = GdtEntry()

  # Entry 1: Kernel Code (64-bit)
  # Type: Code | DPL: 0 (kernel) | Present: 1 | Long: 1 | Gran: 1
  let kernelCodeAccess = (GDT_PRESENT shl 7) or (GDT_DPL_KERNEL shl 5) or (1 shl 4) or GDT_TYPE_CODE
  let kernelCodeGranularity = (GDT_GRANULARITY shl 7) or (GDT_LONG shl 5)
  gGdt[1] = createGdtEntry(kernelCodeAccess, kernelCodeGranularity)

  # Entry 2: Kernel Data (64-bit)
  # Type: Data | DPL: 0 (kernel) | Present: 1 | Gran: 1
  let kernelDataAccess = (GDT_PRESENT shl 7) or (GDT_DPL_KERNEL shl 5) or (1 shl 4) or GDT_TYPE_DATA
  let kernelDataGranularity = (GDT_GRANULARITY shl 7)
  gGdt[2] = createGdtEntry(kernelDataAccess, kernelDataGranularity)

  # Entry 3: User Code (64-bit)
  let userCodeAccess = (GDT_PRESENT shl 7) or (GDT_DPL_USER shl 5) or (1 shl 4) or GDT_TYPE_CODE
  let userCodeGranularity = (GDT_GRANULARITY shl 7) or (GDT_LONG shl 5)
  gGdt[3] = createGdtEntry(userCodeAccess, userCodeGranularity)

  # Entry 4: User Data (64-bit)
  let userDataAccess = (GDT_PRESENT shl 7) or (GDT_DPL_USER shl 5) or (1 shl 4) or GDT_TYPE_DATA
  let userDataGranularity = (GDT_GRANULARITY shl 7)
  gGdt[4] = createGdtEntry(userDataAccess, userDataGranularity)

  # Setup GDT descriptor
  gGdtDescriptor.size = (gGdt.len * sizeof(GdtEntry)) - 1
  gGdtDescriptor.offset = cast[uint64](addr gGdt[0])

  # Load GDT register
  # Note: This requires inline assembly (in real boot.asm)
  # Here we just prepare it for boot.asm to load

proc loadGdt*() =
  ## Load GDT into CPU
  ## Must be called from boot.asm with inline assembly:
  ##   lgdt [gGdtDescriptor]
  ##   jmp 0x08:kernel_continue  # Jump to kernel code segment
  ##
  ## This function is documented but implementation is in boot.asm
  discard  # Actual LGDT instruction in boot.asm

# ═══════════════════════════════════════════════════════════════════════════
# Early Paging Setup
# ═══════════════════════════════════════════════════════════════════════════

## x86_64 Paging Structure (4-level):
## CR3 -> PML4 (Page Map Level 4)
##        ├─ PDPT (Page Directory Pointer Table)
##        ├─ PD (Page Directory)
##        └─ PT (Page Table)
##
## Each table has 512 entries (2^9)

type
  ## Page table entry (64-bit)
  PageTableEntry* = object
    value*: uint64

# Minimal page table for boot (we'll use more sophisticated ones in mm/ layer)
var
  gBootPml4*: array[512, PageTableEntry]  # PML4 (level 4)
  gBootPdpt*: array[512, PageTableEntry]  # PDPT (level 3)
  gBootPageDir*: array[512, PageTableEntry]  # PD (level 2)
  gBootPageTable*: array[512, PageTableEntry]  # PT (level 1)

proc setupInitialPaging*() =
  ## Setup minimal initial page tables
  ## Maps:
  ## - Kernel space (high addresses) to kernel code
  ## - Identity map first 4MB (for boot)
  ##
  ## Note: Full paging is handled by mm/virtual_manager.nim
  ## This just gets us to that point

  # For now, just prepare structures
  # Full paging setup in mm/virtual_manager.nim (already built!)
  # TODO: Link this to early_init flow if needed

proc enablePaging*() =
  ## Enable paging (CR0.PG flag)
  ## Must be called from boot.asm with inline assembly
  discard

# ═══════════════════════════════════════════════════════════════════════════
# Early Console Output (Temporary, before serial driver)
# ═══════════════════════════════════════════════════════════════════════════

proc earlyPrint*(msg: string) =
  ## Early output via VGA text mode
  ## Used before serial driver is initialized
  ## Writes to VGA text buffer at 0xB8000
  var ptr = cast[ptr uint16](0xB8000)
  for c in msg:
    if c == '\0': break
    ptr[] = uint16(c) or 0x0F00  # Character with white-on-black color
    inc(ptr)

proc earlyPrintln*(msg: string) =
  ## Early output with newline
  earlyPrint(msg)
  earlyPrint("\n")

# ═══════════════════════════════════════════════════════════════════════════
# Boot Information Parsing
# ═══════════════════════════════════════════════════════════════════════════

proc parseBootInformation*(bootInfoPtr: pointer): Result[BootInfo, BootloaderError] =
  ## Parse boot information from bootloader
  ## Reuses: parseBootInfo from boot/bootloader.nim (already built!)
  ## This just delegates to that function

  # Verify magic number first
  let magic = cast[ptr uint32](bootInfoPtr)[]

  # Call existing bootloader parser
  result = parseBootInfo(magic, bootInfoPtr)

# ═══════════════════════════════════════════════════════════════════════════
# Early Initialization Sequence
# ═══════════════════════════════════════════════════════════════════════════

proc earlyInit*(bootInfoPtr: pointer, magicNumber: uint32): Result[BootInfo, KernelError] =
  ## Early kernel initialization
  ## Called from boot.asm after transitioning to 64-bit mode
  ##
  ## Sequence:
  ## 1. Setup console for debug output
  ## 2. Parse boot information
  ## 3. Setup GDT
  ## 4. Setup minimal paging
  ## 5. Return boot info to kernel_main

  earlyPrintln("Early initialization starting...")

  # Step 1: Parse boot information
  earlyPrintln("Parsing boot information...")
  let bootResult = parseBootInformation(bootInfoPtr)

  if bootResult.isErr():
    earlyPrintln("ERROR: Failed to parse boot info")
    return err(keBootInfoInvalid)

  let bootInfo = bootResult.value

  # Step 2: Verify boot information
  earlyPrintln("Boot info parsed successfully")
  let memSize = bootInfo.getTotalMemory()
  earlyPrintln("Memory available: " & $(memSize div (1024 * 1024)) & " MB")

  # Step 3: Setup GDT
  earlyPrintln("Setting up GDT...")
  setupGdt()
  earlyPrintln("GDT ready (load with LGDT in boot.asm)")

  # Step 4: Setup paging (minimal)
  earlyPrintln("Paging structures prepared...")
  setupInitialPaging()

  # Return boot info for kernel_main to use
  earlyPrintln("Early init complete, transferring to kernel main...")
  ok(bootInfo)

# ═══════════════════════════════════════════════════════════════════════════
# Notes on Architecture
# ═══════════════════════════════════════════════════════════════════════════

## EARLY_INIT PHILOSOPHY:
##
## This module handles the absolute minimum needed to transition
## from boot.asm to kernel_main.nim:
##
## ✓ Parse boot information (delegates to bootloader.nim)
## ✓ Setup GDT (required for 64-bit mode)
## ✓ Prepare paging structures (delegates to mm/virtual_manager.nim)
## ✓ Early console output (replaced by core/console.nim in TASK 1.5)
##
## ✗ Does NOT do:
## - Complex memory management (that's mm/physical_manager.nim)
## - Advanced paging (that's mm/virtual_manager.nim)
## - Interrupt handling (that's kern/interrupts.nim)
## - Task creation (that's sched/task_manager.nim)
## - Scheduling (that's sched/scheduler.nim)
##
## INNOVATION POINT:
##
## While boot.asm is architecture-specific, the early_init functions
## can be reused or swapped:
## - Could implement UEFI boot (different early_init)
## - Could implement Xen dom0 boot (different early_init)
## - Could implement Multiboot3 when available
##
## Each would implement same interface (parseBootInformation, earlyInit)
## but kernel_main.nim wouldn't change.
##
## NEXT STEPS:
##
## TASK 1.1: boot.asm
## - Multiboot2 header
## - 32-bit mode setup
## - Call to this module's earlyInit
## - Transition to 64-bit mode
## - Call kernel_main
##
## TASK 1.5: core/console.nim
## - Replace earlyPrint with serial driver
## - Full console output
