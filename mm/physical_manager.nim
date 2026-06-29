# SPDX-License-Identifier: GPL-2.0
## Physical Memory Manager - LAYER 2
##
## Owns physical frame allocation using a bitmap allocator.
## Dependencies: types, boot_info, spinlock

import ../core/types
import ../arch/common/boot_info
import ../sync/spinlock

type
  # ═══════════════════════════════════════════════════════════════════════════
  # Error Types
  # ═══════════════════════════════════════════════════════════════════════════

  FrameError* = enum
    ## Physical frame allocation errors
    feNone = 0
    feOutOfFrames       ## No free frames available
    feInvalidFrame      ## Invalid frame address
    feDoubleFree        ## Frame already free
    feNotAllocated      ## Frame was not allocated

  # ═══════════════════════════════════════════════════════════════════════════
  # Memory Zones
  # ═══════════════════════════════════════════════════════════════════════════

  Zone* = enum
    ## Memory zones for different allocation requirements
    zoneDma       ## 0-16MB (ISA DMA)
    zoneDma32     ## 16MB-4GB (32-bit DMA)
    zoneNormal    ## 4GB+ (normal allocations)

  ZoneInfo* = object
    ## Information about a memory zone
    startFrame*: uint64     ## First frame number
    endFrame*: uint64       ## Last frame number + 1
    freeFrames*: uint64     ## Number of free frames
    totalFrames*: uint64    ## Total frames in zone

  # ═══════════════════════════════════════════════════════════════════════════
  # Physical Memory Manager
  # ═══════════════════════════════════════════════════════════════════════════

  PhysicalMemManager* = ref object
    ## Physical memory manager state: bitmap-based frame allocator.
    ##
    ## Bitmap strategy: 1 bit per 4KB frame; 1 = allocated, 0 = free.
    ## Zones partition memory for ISA DMA (0-16MB), 32-bit DMA (16MB-4GB), normal (4GB+).

    bitmap*: ptr UncheckedArray[uint64]   ## Bitmap of frame allocation (uint64-aligned)
    bitmapSize*: uint64                   ## Size in uint64 words (one bit per frame)

    totalFrames*: uint64                  ## Total physical frames (fixed at init)
    usedFrames*: uint64                   ## Currently allocated frames (monotonic within alloc/free)
    reservedFrames*: uint64               ## Reserved frames (unusable, e.g., BIOS ROM)

    zones*: array[Zone, ZoneInfo]         ## Zone boundaries and free counts

    lock*: SpinLock                       ## IRQ-safe spinlock protecting bitmap + counts

    # Statistics
    allocCount*: uint64       ## Total allocations
    freeCount*: uint64        ## Total frees

const
  BitsPerWord = 64
  DmaLimit = 16 * MiB
  Dma32Limit = 4 * GiB

# ═══════════════════════════════════════════════════════════════════════════
# Bitmap Operations
# ═══════════════════════════════════════════════════════════════════════════

proc frameToIndex(frame: uint64): tuple[word: int, bit: int] {.inline.} =
  ## Convert frame number to bitmap index
  (int(frame div BitsPerWord), int(frame mod BitsPerWord))

proc isFrameUsed(self: PhysicalMemManager, frame: uint64): bool {.inline.} =
  ## Check if frame is marked as used
  let (word, bit) = frameToIndex(frame)
  if word >= int(self.bitmapSize):
    return true  # Out of range = used
  (self.bitmap[word] and (1'u64 shl bit)) != 0

proc markFrameUsed(self: PhysicalMemManager, frame: uint64) {.inline.} =
  ## Mark frame as used
  let (word, bit) = frameToIndex(frame)
  if word < int(self.bitmapSize):
    self.bitmap[word] = self.bitmap[word] or (1'u64 shl bit)

proc markFrameFree(self: PhysicalMemManager, frame: uint64) {.inline.} =
  ## Mark frame as free
  let (word, bit) = frameToIndex(frame)
  if word < int(self.bitmapSize):
    self.bitmap[word] = self.bitmap[word] and not (1'u64 shl bit)

proc findFirstFreeInWord(word: uint64): int {.inline.} =
  ## Find first zero bit in word, returns -1 if none
  if word == high(uint64):
    return -1
  # Find first zero (complement and find first one)
  let inverted = not word
  # Count trailing zeros to find first set bit
  var n = 0
  var v = inverted
  if (v and 0xFFFFFFFF'u64) == 0:
    n += 32
    v = v shr 32
  if (v and 0xFFFF'u64) == 0:
    n += 16
    v = v shr 16
  if (v and 0xFF'u64) == 0:
    n += 8
    v = v shr 8
  if (v and 0xF'u64) == 0:
    n += 4
    v = v shr 4
  if (v and 0x3'u64) == 0:
    n += 2
    v = v shr 2
  if (v and 0x1'u64) == 0:
    n += 1
  return n

# ═══════════════════════════════════════════════════════════════════════════
# Initialization
# ═══════════════════════════════════════════════════════════════════════════

proc getZoneForFrame(frame: uint64): Zone =
  ## Determine which zone a frame belongs to
  let address = frame * FrameSize
  if address < DmaLimit:
    zoneDma
  elif address < Dma32Limit:
    zoneDma32
  else:
    zoneNormal

proc initFromBootInfo*(self: PhysicalMemManager, bootInfo: ptr BootInfo,
                       bitmapAddr: pointer) =
  ## Initialize physical memory manager from boot info
  ## bitmapAddr must point to pre-allocated bitmap memory

  # Calculate total frames from highest USABLE address only
  # (excluding reserved MMIO regions at very high addresses like PCI @ 1TB)
  let highestAddr = getHighestUsableAddress(bootInfo[])
  self.totalFrames = (uint64(highestAddr) + FrameSize - 1) div FrameSize

  # Setup bitmap
  self.bitmapSize = (self.totalFrames + BitsPerWord - 1) div BitsPerWord
  self.bitmap = cast[ptr UncheckedArray[uint64]](bitmapAddr)

  # Mark all frames as used initially
  for i in 0..<int(self.bitmapSize):
    self.bitmap[i] = high(uint64)
  self.usedFrames = self.totalFrames
  self.reservedFrames = 0

  # Setup zone boundaries
  self.zones[zoneDma].startFrame = 0
  self.zones[zoneDma].endFrame = min(self.totalFrames, DmaLimit div FrameSize)

  self.zones[zoneDma32].startFrame = self.zones[zoneDma].endFrame
  self.zones[zoneDma32].endFrame = min(self.totalFrames, Dma32Limit div FrameSize)

  self.zones[zoneNormal].startFrame = self.zones[zoneDma32].endFrame
  self.zones[zoneNormal].endFrame = self.totalFrames

  for zone in Zone:
    self.zones[zone].totalFrames = self.zones[zone].endFrame - self.zones[zone].startFrame
    self.zones[zone].freeFrames = 0

  # Determine the end of kernel image — we must NOT free frames that
  # overlap with kernel code/data/BSS (including the ARC heap).
  let kernelEndAddr = alignUp(uint64(bootInfo.kernelPhysEnd), FrameSize)
  let kernelEndFrame = kernelEndAddr div FrameSize

  # Free available regions from memory map (excluding kernel image)
  for i in 0..<bootInfo.memoryMap.count:
    let region = bootInfo.memoryMap.regions[i]
    if region.regionType == memAvailable:
      let startFrame = alignUp(uint64(region.base), FrameSize) div FrameSize
      let endFrame = (uint64(region.base) + region.length) div FrameSize

      for frame in startFrame..<endFrame:
        if frame < self.totalFrames and frame >= kernelEndFrame:
          self.markFrameFree(frame)
          dec self.usedFrames
          let zone = getZoneForFrame(frame)
          inc self.zones[zone].freeFrames

  # Reserve bitmap frames — the bitmap itself is placed right after the
  # kernel image, and we must not let allocFrame() give them out.
  let bitmapStartFrame = cast[uint64](bitmapAddr) div FrameSize
  let bitmapBytes = self.bitmapSize * 8  # bitmapSize is in uint64 words
  let bitmapEndAddr = cast[uint64](bitmapAddr) + bitmapBytes
  let bitmapEndFrame = alignUp(bitmapEndAddr, FrameSize) div FrameSize
  for frame in bitmapStartFrame..<bitmapEndFrame:
    if frame < self.totalFrames and not self.isFrameUsed(frame):
      self.markFrameUsed(frame)
      inc self.usedFrames

  # Initialize lock
  self.lock.init()

# ═══════════════════════════════════════════════════════════════════════════
# Frame Allocation
# ═══════════════════════════════════════════════════════════════════════════

proc allocFrameInRange(self: PhysicalMemManager,
                       startFrame, endFrame: uint64): Result[PhysAddr, FrameError] =
  ## Allocate a frame within specified range (internal, lock must be held)
  let startWord = int(startFrame div BitsPerWord)
  let endWord = int((endFrame + BitsPerWord - 1) div BitsPerWord)

  for wordIdx in startWord..<min(endWord, int(self.bitmapSize)):
    let word = self.bitmap[wordIdx]
    if word != high(uint64):
      let bit = findFirstFreeInWord(word)
      if bit >= 0:
        let frame = uint64(wordIdx) * BitsPerWord + uint64(bit)
        if frame >= startFrame and frame < endFrame:
          self.markFrameUsed(frame)
          inc self.usedFrames
          inc self.allocCount
          let zone = getZoneForFrame(frame)
          dec self.zones[zone].freeFrames
          return ok(PhysAddr(frame * FrameSize))

  err(feOutOfFrames)

# Zone fallback order: when a zone runs out of frames, try these alternatives.
const FallbackOrder: array[Zone, array[2, Zone]] = [
  zoneDma:    [zoneDma32, zoneNormal],
  zoneDma32:  [zoneNormal, zoneDma],
  zoneNormal: [zoneDma32, zoneDma]
]

proc allocFrame*(self: PhysicalMemManager,
                 zone: Zone = zoneNormal): Result[PhysAddr, FrameError] =
  ## Allocate a single physical frame from specified zone.
  ## Falls back to wider zones if the requested zone is exhausted or empty.
  self.lock.acquire()
  defer: self.lock.release()

  # Try requested zone first
  result = self.allocFrameInRange(self.zones[zone].startFrame,
                                   self.zones[zone].endFrame)
  if result.isOk:
    return

  # Fall back through the pre-computed lookup table
  for fallback in FallbackOrder[zone]:
    result = self.allocFrameInRange(self.zones[fallback].startFrame,
                                     self.zones[fallback].endFrame)
    if result.isOk:
      return

proc freeFrame*(self: PhysicalMemManager, frame: PhysAddr): Result[void, FrameError] =
  ## Free a physical frame
  let frameNum = uint64(frame) div FrameSize

  self.lock.acquire()
  defer: self.lock.release()

  if frameNum >= self.totalFrames:
    return err(feInvalidFrame)

  if not self.isFrameUsed(frameNum):
    return err(feDoubleFree)

  self.markFrameFree(frameNum)
  dec self.usedFrames
  inc self.freeCount
  let zone = getZoneForFrame(frameNum)
  inc self.zones[zone].freeFrames

  ok()

proc allocContiguous*(self: PhysicalMemManager, count: int,
                      zone: Zone = zoneNormal): Result[PhysAddr, FrameError] =
  ## Allocate contiguous physical frames
  if count <= 0:
    return err(feInvalidFrame)
  if count == 1:
    return self.allocFrame(zone)

  self.lock.acquire()
  defer: self.lock.release()

  let startFrame = self.zones[zone].startFrame
  let endFrame = self.zones[zone].endFrame

  var consecutive = 0
  var firstFrame: uint64 = 0

  for frame in startFrame..<endFrame:
    if not self.isFrameUsed(frame):
      if consecutive == 0:
        firstFrame = frame
      inc consecutive
      if consecutive == count:
        # Found enough contiguous frames
        for i in 0..<count:
          self.markFrameUsed(firstFrame + uint64(i))
          inc self.usedFrames
          inc self.allocCount
          dec self.zones[zone].freeFrames
        return ok(PhysAddr(firstFrame * FrameSize))
    else:
      consecutive = 0

  err(feOutOfFrames)

proc freeContiguous*(self: PhysicalMemManager, frame: PhysAddr,
                     count: int): Result[void, FrameError] =
  ## Free contiguous physical frames
  for i in 0..<count:
    let res = self.freeFrame(frame + uint64(i) * FrameSize)
    if res.isErr:
      return res
  ok()

# ═══════════════════════════════════════════════════════════════════════════
# Information
# ═══════════════════════════════════════════════════════════════════════════

proc freeFrames*(self: PhysicalMemManager): uint64 =
  ## Get total free frames
  self.totalFrames - self.usedFrames

proc freeMemory*(self: PhysicalMemManager): uint64 =
  ## Get free memory in bytes
  self.freeFrames() * FrameSize

proc usedMemory*(self: PhysicalMemManager): uint64 =
  ## Get used memory in bytes
  self.usedFrames * FrameSize

proc totalMemory*(self: PhysicalMemManager): uint64 =
  ## Get total memory in bytes
  self.totalFrames * FrameSize

proc zoneInfo*(self: PhysicalMemManager, zone: Zone): ZoneInfo =
  ## Get zone information
  self.zones[zone]

proc zoneFragmentation*(self: PhysicalMemManager, zone: Zone): float =
  ## Calculate fragmentation ratio for a zone (0.0 = no fragmentation, 1.0 = highly fragmented)
  let zoneInfo = self.zones[zone]
  if zoneInfo.freeFrames == 0:
    return 0.0

  # Estimate fragmentation by checking free blocks
  # This is a simplified measure - real implementation would track block sizes
  let avgBlockSize = if zoneInfo.freeFrames > 0:
    max(1'u64, zoneInfo.totalFrames div (zoneInfo.freeFrames + 1))
  else:
    1'u64

  let fragmentation = 1.0 - (float(avgBlockSize) / float(zoneInfo.totalFrames))
  max(0.0, min(1.0, fragmentation))

# ═══════════════════════════════════════════════════════════════════════════
# Physical Memory Helpers (identity-mapped access)
# ═══════════════════════════════════════════════════════════════════════════
#
# These helpers let us read/write physical memory directly via the boot
# stub's identity mapping (physical 0-64 MB → virtual 0-64 MB).
#
# WARNING: Once we implement proper higher-half physical memory mapping,
# these must be updated to translate through the physmap region.

proc physPtr*[T](phys: PhysAddr): ptr T {.inline.} =
  ## Return a typed pointer to a physical address via identity mapping.
  ##
  ## Current limitation: phys must be within 0-64 MB (boot stub identity
  ## map). Future versions will translate through a physmap VMO.
  cast[ptr T](uint64(phys))

proc zeroPhysPage*(phys: PhysAddr) {.inline.} =
  ## Zero a 4 KB physical frame by writing through the identity mapping.
  ##
  ## This is required because allocFrame() does NOT zero returned frames.
  let p = physPtr[ptr UncheckedArray[uint64]](phys)
  let count = int(FrameSize) div sizeof(uint64)  # 512 entries
  for i in 0..<int(count):
    p[i] = 0

proc isFrameInZone*(self: PhysicalMemManager, frame: PhysAddr, zone: Zone): bool {.inline.} =
  ## Check if frame is in specified zone
  let frameNum = uint64(frame) div FrameSize
  frameNum >= self.zones[zone].startFrame and frameNum < self.zones[zone].endFrame

proc validateFrame*(self: PhysicalMemManager, frame: PhysAddr): Result[void, FrameError] =
  ## Validate frame address
  let frameNum = uint64(frame) div FrameSize

  if frameNum >= self.totalFrames:
    return err(feInvalidFrame)

  if uint64(frame) mod FrameSize != 0:
    return err(feInvalidFrame)

  ok()

proc stats*(self: PhysicalMemManager): string =
  ## Get human-readable statistics
  var stats = ""
  stats &= "Physical Memory Manager Stats:\n"
  stats &= "  Total Frames: " & $self.totalFrames & " (" & $(self.totalMemory() div (1024*1024)) & " MB)\n"
  stats &= "  Used Frames: " & $self.usedFrames & " (" & $(self.usedMemory() div (1024*1024)) & " MB)\n"
  stats &= "  Free Frames: " & $self.freeFrames() & " (" & $(self.freeMemory() div (1024*1024)) & " MB)\n"
  stats &= "  Total Allocations: " & $self.allocCount & "\n"
  stats &= "  Total Frees: " & $self.freeCount & "\n"

  for zone in Zone:
    let zinfo = self.zones[zone]
    let frag = self.zoneFragmentation(zone)
    stats &= "  Zone " & $zone & ":\n"
    stats &= "    Total: " & $zinfo.totalFrames & " frames\n"
    stats &= "    Free: " & $zinfo.freeFrames & " frames\n"
    stats &= "    Fragmentation: " & $(frag * 100) & "%\n"

  stats
