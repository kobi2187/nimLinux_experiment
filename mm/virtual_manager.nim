# SPDX-License-Identifier: GPL-2.0
## Virtual Memory Manager - LAYER 2
##
## Owns page tables and virtual address space mappings.
## Dependencies: types, physical_manager, spinlock

import ../core/types
import ./physical_manager
import ../sync/spinlock
import ../core/serial

when defined(amd64) or defined(x86_64):
  import ../arch/x86_64/cpu_primitives

# Debug: flag to control verbosity
const vmDbg = false

type
  # ═══════════════════════════════════════════════════════════════════════════
  # Page Flags
  # ═══════════════════════════════════════════════════════════════════════════

  PageFlags* = enum
    ## Page table entry flags
    pfPresent       ## Page is present in memory
    pfWritable      ## Page is writable
    pfUser          ## Page is accessible from user mode
    pfWriteThrough  ## Write-through caching
    pfCacheDisable  ## Caching disabled
    pfAccessed      ## Page has been accessed
    pfDirty         ## Page has been written to
    pfHuge          ## Huge page (2MB or 1GB)
    pfGlobal        ## Global page (not flushed on CR3 change)
    pfNoExecute     ## No-execute bit (requires NX support)

  # ═══════════════════════════════════════════════════════════════════════════
  # Error Types
  # ═══════════════════════════════════════════════════════════════════════════

  MappingError* = enum
    ## Virtual memory mapping errors
    meNone = 0
    meOutOfMemory       ## No physical memory for page tables
    meAlreadyMapped     ## Address already mapped
    meNotMapped         ## Address not mapped
    meInvalidAddress    ## Invalid virtual address
    mePermissionDenied  ## Permission violation
    meInvalidFlags      ## Invalid flag combination

  # ═══════════════════════════════════════════════════════════════════════════
  # Virtual Memory Region
  # ═══════════════════════════════════════════════════════════════════════════

  VmRegion* = object
    ## Describes a virtual memory region
    start*: VirtAddr        ## Start address
    length*: uint64         ## Length in bytes
    flags*: set[PageFlags]  ## Protection flags
    name*: array[32, char]  ## Region name for debugging

  # ═══════════════════════════════════════════════════════════════════════════
  # Address Space
  # ═══════════════════════════════════════════════════════════════════════════

  AddressSpace* = ref object
    ## A complete virtual address space
    root*: PhysAddr           ## CR3 value (PML4 physical address)
    regions*: seq[VmRegion]   ## Mapped regions
    lock*: SpinLock           ## Per-address-space lock
    refCount*: int            ## Reference count

  # ═══════════════════════════════════════════════════════════════════════════
  # Virtual Memory Manager
  # ═══════════════════════════════════════════════════════════════════════════

  VirtualMemManager* = ref object
    ## Virtual memory manager state
    physMgr*: PhysicalMemManager  ## Physical memory manager dependency
    kernelSpace*: AddressSpace    ## Kernel address space
    lock*: SpinLock               ## Global lock

# ═══════════════════════════════════════════════════════════════════════════
# Page Table Constants
# ═══════════════════════════════════════════════════════════════════════════

const
  # Page table entry bits
  PTE_PRESENT*    = 1'u64 shl 0
  PTE_WRITABLE*   = 1'u64 shl 1
  PTE_USER*       = 1'u64 shl 2
  PTE_PWT*        = 1'u64 shl 3
  PTE_PCD*        = 1'u64 shl 4
  PTE_ACCESSED*   = 1'u64 shl 5
  PTE_DIRTY*      = 1'u64 shl 6
  PTE_HUGE*       = 1'u64 shl 7
  PTE_GLOBAL*     = 1'u64 shl 8
  PTE_NX*         = 1'u64 shl 63

  # Address masks
  PTE_ADDR_MASK*  = 0x000FFFFFFFFFF000'u64  ## Physical address mask
  PTE_FLAGS_MASK* = 0xFFF0000000000FFF'u64  ## Flags mask

  # Page table sizes
  PT_ENTRIES* = 512       ## Entries per page table
  PT_SIZE* = 4096         ## Page table size in bytes

  # Virtual address parts
  PML4_SHIFT* = 39
  PDPT_SHIFT* = 30
  PD_SHIFT* = 21
  PT_SHIFT* = 12
  INDEX_MASK* = 0x1FF     ## 9 bits

# ═══════════════════════════════════════════════════════════════════════════
# Address Space Management
# ═══════════════════════════════════════════════════════════════════════════

proc newVirtualMemManager*(physMgr: PhysicalMemManager): VirtualMemManager =
  ## Create a new virtual memory manager
  when vmDbg: kprintln("  [VM] newVirtualMemManager: creating object")
  result = VirtualMemManager(
    physMgr: physMgr
  )
  when vmDbg: kprintln("  [VM] newVirtualMemManager: init lock")
  result.lock.init()
  when vmDbg: kprintln("  [VM] newVirtualMemManager: done")

proc createAddressSpace*(self: VirtualMemManager): Result[AddressSpace, MappingError] =
  ## Create a new address space with fresh page tables
  let rootFrame = self.physMgr.allocFrame()
  if rootFrame.isErr:
    return err(meOutOfMemory)

  # Zero the entire PML4 page (inline to avoid cross-module zeroPhysPage issue)
  let pz = cast[ptr array[512, uint64]](uint64(rootFrame.value))
  for i in 0..<512:
    pz[i] = 0

  let space = AddressSpace(
    root: rootFrame.value,
    regions: @[],
    refCount: 1
  )
  space.lock.init()
  ok(space)

proc destroyAddressSpace*(self: VirtualMemManager, space: AddressSpace) =
  ## Destroy an address space and free all page tables
  # TODO: Walk and free all page tables
  discard self.physMgr.freeFrame(space.root)

proc initKernelSpace*(self: VirtualMemManager): Result[void, MappingError] =
  ## Initialize kernel address space
  ##
  ## Creates a fresh PML4, copies the identity mapping (PML4[0]) from the
  ## boot stub's page tables (currently loaded in CR3), then switches CR3
  ## to the new PML4 so that both the lower-half identity mapping AND the
  ## higher-half kernel mappings are visible to the CPU.
  let space = ?self.createAddressSpace()
  self.kernelSpace = space

  let oldCr3 = PhysAddr(readCr3())
  let oldPml4 = physPtr[array[PT_ENTRIES, uint64]](oldCr3)
  let newPml4 = physPtr[array[PT_ENTRIES, uint64]](space.root)

  # Copy identity mapping (PML4[0]) from boot stub page tables
  newPml4[0] = oldPml4[0]

  # Switch CR3 to the new kernel address space (flushes TLB)
  writeCr3(uint64(space.root))
  ok()

# ═══════════════════════════════════════════════════════════════════════════
# Page Table Walking
# ═══════════════════════════════════════════════════════════════════════════

type VirtIndices* = tuple[pml4, pdpt, pd, pt: int]
  ## All four page table indices for a virtual address

proc getVirtIndex*(virt: VirtAddr, level: int): int {.inline.} =
  ## Get page table index for address at given level
  let shift = case level
    of 4: PML4_SHIFT
    of 3: PDPT_SHIFT
    of 2: PD_SHIFT
    of 1: PT_SHIFT
    else: 0
  int((uint64(virt) shr shift) and INDEX_MASK)

proc virtIndices*(virt: VirtAddr): VirtIndices {.inline.} =
  ## Compute all four page table indices for a virtual address at once.
  let v = uint64(virt)
  result.pml4 = int((v shr PML4_SHIFT) and INDEX_MASK)
  result.pdpt = int((v shr PDPT_SHIFT) and INDEX_MASK)
  result.pd   = int((v shr PD_SHIFT) and INDEX_MASK)
  result.pt   = int((v shr PT_SHIFT) and INDEX_MASK)

proc flagsToEntry(flags: set[PageFlags]): uint64 =
  ## Convert page flags to PTE bits
  result = PTE_PRESENT
  if pfWritable in flags: result = result or PTE_WRITABLE
  if pfUser in flags: result = result or PTE_USER
  if pfWriteThrough in flags: result = result or PTE_PWT
  if pfCacheDisable in flags: result = result or PTE_PCD
  if pfHuge in flags: result = result or PTE_HUGE
  if pfGlobal in flags: result = result or PTE_GLOBAL
  if pfNoExecute in flags: result = result or PTE_NX

proc entryToFlags(entry: uint64): set[PageFlags] =
  ## Convert PTE bits to page flags
  result = {}
  if (entry and PTE_PRESENT) != 0: result.incl pfPresent
  if (entry and PTE_WRITABLE) != 0: result.incl pfWritable
  if (entry and PTE_USER) != 0: result.incl pfUser
  if (entry and PTE_PWT) != 0: result.incl pfWriteThrough
  if (entry and PTE_PCD) != 0: result.incl pfCacheDisable
  if (entry and PTE_ACCESSED) != 0: result.incl pfAccessed
  if (entry and PTE_DIRTY) != 0: result.incl pfDirty
  if (entry and PTE_HUGE) != 0: result.incl pfHuge
  if (entry and PTE_GLOBAL) != 0: result.incl pfGlobal
  if (entry and PTE_NX) != 0: result.incl pfNoExecute

# ═══════════════════════════════════════════════════════════════════════════
# Page Mapping
# ═══════════════════════════════════════════════════════════════════════════

proc getOrCreateTable(self: VirtualMemManager, parent: ptr uint64,
                      flags: uint64): Result[ptr array[PT_ENTRIES, uint64], MappingError] =
  ## Get or create a page table entry
  if (parent[] and PTE_PRESENT) != 0:
    # Table exists — extract physical address from the PTE
    let tablePhys = PhysAddr(parent[] and PTE_ADDR_MASK)
    return ok(physPtr[array[PT_ENTRIES, uint64]](tablePhys))

  # Need to allocate new table
  let frame = self.physMgr.allocFrame()
  if frame.isErr:
    return err(meOutOfMemory)

  # Zero the new table before use (inline to avoid zeroPhysPage issue)
  let zt = cast[ptr array[PT_ENTRIES, uint64]](uint64(frame.value))
  for i in 0..<PT_ENTRIES:
    zt[i] = 0
  let table = physPtr[array[PT_ENTRIES, uint64]](frame.value)

  # Set parent entry
  parent[] = uint64(frame.value) or flags or PTE_PRESENT

  ok(table)

proc mapPage*(self: VirtualMemManager, space: AddressSpace,
              virt: VirtAddr, phys: PhysAddr,
              flags: set[PageFlags]): Result[void, MappingError] =
  space.lock.acquire()
  defer: space.lock.release()

  let idx = virtIndices(virt)
  let pml4 = physPtr[array[PT_ENTRIES, uint64]](space.root)

  # Walk/create page tables
  let tableFlags = PTE_WRITABLE or PTE_USER  # Intermediate tables are permissive

  let pdpt = ?self.getOrCreateTable(addr pml4[idx.pml4], tableFlags)
  let pd = ?self.getOrCreateTable(addr pdpt[idx.pdpt], tableFlags)
  let pt = ?self.getOrCreateTable(addr pd[idx.pd], tableFlags)

  # Check if already mapped
  if (pt[idx.pt] and PTE_PRESENT) != 0:
    return err(meAlreadyMapped)

  # Set the page table entry
  pt[idx.pt] = uint64(phys) or flagsToEntry(flags)

  ok()

proc unmapPage*(self: VirtualMemManager, space: AddressSpace,
                virt: VirtAddr): Result[PhysAddr, MappingError] =
  ## Unmap a page, return physical address
  space.lock.acquire()
  defer: space.lock.release()

  let idx = virtIndices(virt)
  let pml4 = physPtr[array[PT_ENTRIES, uint64]](space.root)

  if (pml4[idx.pml4] and PTE_PRESENT) == 0:
    return err(meNotMapped)

  let pdpt = physPtr[array[PT_ENTRIES, uint64]](PhysAddr(pml4[idx.pml4] and PTE_ADDR_MASK))

  if (pdpt[idx.pdpt] and PTE_PRESENT) == 0:
    return err(meNotMapped)

  let pd = physPtr[array[PT_ENTRIES, uint64]](PhysAddr(pdpt[idx.pdpt] and PTE_ADDR_MASK))

  if (pd[idx.pd] and PTE_PRESENT) == 0:
    return err(meNotMapped)

  let pt = physPtr[array[PT_ENTRIES, uint64]](PhysAddr(pd[idx.pd] and PTE_ADDR_MASK))

  if (pt[idx.pt] and PTE_PRESENT) == 0:
    return err(meNotMapped)

  let phys = PhysAddr(pt[idx.pt] and PTE_ADDR_MASK)
  pt[idx.pt] = 0

  ok(phys)

proc mapRegion*(self: VirtualMemManager, space: AddressSpace,
                virt: VirtAddr, phys: PhysAddr, length: uint64,
                flags: set[PageFlags]): Result[void, MappingError] =
  ## Map a contiguous region
  var offset: uint64 = 0
  while offset < length:
    ?self.mapPage(space, virt + offset, phys + offset, flags)
    offset += FrameSize
  ok()

proc translate*(self: VirtualMemManager, space: AddressSpace,
                virt: VirtAddr): Result[PhysAddr, MappingError] =
  ## Translate virtual to physical address
  let idx = virtIndices(virt)
  let pml4 = physPtr[array[PT_ENTRIES, uint64]](space.root)

  if (pml4[idx.pml4] and PTE_PRESENT) == 0:
    return err(meNotMapped)

  let pdpt = physPtr[array[PT_ENTRIES, uint64]](PhysAddr(pml4[idx.pml4] and PTE_ADDR_MASK))

  if (pdpt[idx.pdpt] and PTE_PRESENT) == 0:
    return err(meNotMapped)

  # Check for 1GB huge page
  if (pdpt[idx.pdpt] and PTE_HUGE) != 0:
    let base = pdpt[idx.pdpt] and PTE_ADDR_MASK
    let offset = uint64(virt) and 0x3FFFFFFF'u64  # 30-bit offset
    return ok(PhysAddr(base + offset))

  let pd = physPtr[array[PT_ENTRIES, uint64]](PhysAddr(pdpt[idx.pdpt] and PTE_ADDR_MASK))

  if (pd[idx.pd] and PTE_PRESENT) == 0:
    return err(meNotMapped)

  # Check for 2MB huge page
  if (pd[idx.pd] and PTE_HUGE) != 0:
    let base = pd[idx.pd] and PTE_ADDR_MASK
    let offset = uint64(virt) and 0x1FFFFF'u64  # 21-bit offset
    return ok(PhysAddr(base + offset))

  let pt = physPtr[array[PT_ENTRIES, uint64]](PhysAddr(pd[idx.pd] and PTE_ADDR_MASK))

  if (pt[idx.pt] and PTE_PRESENT) == 0:
    return err(meNotMapped)

  let base = pt[idx.pt] and PTE_ADDR_MASK
  let offset = uint64(virt) and 0xFFF'u64  # 12-bit offset
  ok(PhysAddr(base + offset))

# ═══════════════════════════════════════════════════════════════════════════
# Kernel Mappings
# ═══════════════════════════════════════════════════════════════════════════

proc kernelMap*(self: VirtualMemManager, virt: VirtAddr, phys: PhysAddr,
                length: uint64, flags: set[PageFlags]): Result[void, MappingError] =
  ## Map into kernel address space
  self.mapRegion(self.kernelSpace, virt, phys, length, flags)

proc kernelUnmap*(self: VirtualMemManager, virt: VirtAddr,
                  length: uint64): Result[void, MappingError] =
  ## Unmap from kernel address space
  var offset: uint64 = 0
  while offset < length:
    discard ?self.unmapPage(self.kernelSpace, virt + offset)
    offset += FrameSize
  ok()

# ═══════════════════════════════════════════════════════════════════════════
# Address Space Information & Utilities
# ═══════════════════════════════════════════════════════════════════════════

proc getAddressSpaceInfo*(self: VirtualMemManager, space: AddressSpace): string =
  ## Get human-readable information about an address space
  var info = "Address Space Information:\n"
  info &= "  Root (CR3): 0x" & toHex(uint64(space.root)) & "\n"
  info &= "  Regions: " & $space.regions.len & "\n"
  info &= "  Reference Count: " & $space.refCount & "\n"
  for i, region in space.regions:
    info &= "    Region " & $i & ": 0x" & toHex(uint64(region.start)) &
              " - 0x" & toHex(uint64(region.start) + region.length) &
              " (" & $(region.length div 1024) & " KB)\n"
  info

proc validateVirtAddr*(virt: VirtAddr): bool {.inline.} =
  ## Basic validation of virtual address (x86_64 canonical form)
  let adr = uint64(virt)
  # Canonical addresses must have bits 48-63 all 0 or all 1
  let bits = adr shr 48
  bits == 0 or bits == 0xFFFF

proc validateMapping*(virt: VirtAddr, length: uint64): Result[void, MappingError] =
  ## Validate a mapping request
  if not validateVirtAddr(virt):
    return err(meInvalidAddress)

  if length == 0:
    return err(meInvalidAddress)

  if (length mod FrameSize) != 0:
    return err(meInvalidAddress)

  ok()

proc kernelMapRegion*(self: VirtualMemManager, virt: VirtAddr, phys: PhysAddr,
                      length: uint64, flags: set[PageFlags]): Result[void, MappingError] =
  ## Convenience function for mapping kernel regions
  ?validateMapping(virt, length)
  self.kernelMap(virt, phys, length, flags)

proc addRegionInfo*(space: AddressSpace, virt: VirtAddr, length: uint64,
                    flags: set[PageFlags], name: string) =
  ## Add metadata about a mapped region
  var region = VmRegion(
    start: virt,
    length: length,
    flags: flags
  )
  # Copy name
  for i in 0..<min(name.len, 31):
    region.name[i] = name[i]
  if name.len < 32:
    region.name[name.len] = '\0'

  space.regions.add(region)
