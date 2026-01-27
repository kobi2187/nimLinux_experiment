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
    ## Physical memory manager state
    # Bitmap: 1 = used, 0 = free
    bitmap*: ptr UncheckedArray[uint64]
    bitmapSize*: uint64       ## Size in uint64 words

    # Frame counts
    totalFrames*: uint64      ## Total physical frames
    usedFrames*: uint64       ## Currently allocated frames
    reservedFrames*: uint64   ## Reserved (unusable) frames

    # Zone information
    zones*: array[Zone, ZoneInfo]

    # Synchronization
    lock*: SpinLock

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
  let addr = frame * FrameSize
  if addr < DmaLimit:
    zoneDma
  elif addr < Dma32Limit:
    zoneDma32
  else:
    zoneNormal

proc initFromBootInfo*(self: PhysicalMemManager, bootInfo: ptr BootInfo,
                       bitmapAddr: pointer) =
  ## Initialize physical memory manager from boot info
  ## bitmapAddr must point to pre-allocated bitmap memory

  # Calculate total frames from highest address
  let highestAddr = getHighestAddress(bootInfo[])
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

  # Free available regions from memory map
  for i in 0..<bootInfo.memoryMap.count:
    let region = bootInfo.memoryMap.regions[i]
    if region.regionType == memAvailable:
      let startFrame = alignUp(uint64(region.base), FrameSize) div FrameSize
      let endFrame = (uint64(region.base) + region.length) div FrameSize

      for frame in startFrame..<endFrame:
        if frame < self.totalFrames:
          self.markFrameFree(frame)
          dec self.usedFrames
          let zone = getZoneForFrame(frame)
          inc self.zones[zone].freeFrames

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

proc allocFrame*(self: PhysicalMemManager,
                 zone: Zone = zoneNormal): Result[PhysAddr, FrameError] =
  ## Allocate a single physical frame from specified zone
  self.lock.acquire()
  defer: self.lock.release()

  # Try requested zone first
  result = self.allocFrameInRange(self.zones[zone].startFrame,
                                   self.zones[zone].endFrame)
  if result.isOk:
    return

  # Fall back to higher zones
  if zone == zoneDma:
    result = self.allocFrameInRange(self.zones[zoneDma32].startFrame,
                                     self.zones[zoneDma32].endFrame)
    if result.isOk:
      return
    result = self.allocFrameInRange(self.zones[zoneNormal].startFrame,
                                     self.zones[zoneNormal].endFrame)
  elif zone == zoneDma32:
    result = self.allocFrameInRange(self.zones[zoneNormal].startFrame,
                                     self.zones[zoneNormal].endFrame)

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
