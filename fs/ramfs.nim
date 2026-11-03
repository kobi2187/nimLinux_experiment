# SPDX-License-Identifier: GPL-2.0
## ramfs — small RAM-backed block filesystem behind the VFS FSDriver interface
## ====================================================================
##
## 32 × 512 B blocks in RAM with a simulated erase-before-write flash and
## least-erased block allocation. Volatile, flat namespace, one block per file.
## Oskit role: VFS test double and scratch volume. NOT littlefs (renamed from
## littlefs_wearleveling, DECISIONS 2026-10-26); real littlefs goes behind the
## same FSDriver interface after a Nim-ecosystem survey. Prefix "/ram/".

import ../core/log
import vfs

# =============================================================================
# Core structures
# =============================================================================

type
  FlashDevice = object
    blockCount: int
    blockSize: int
    storage: seq[byte]

  LittleFsState = object
    dev: FlashDevice
    eraseCycles: seq[int]      ## Erase cycle tracking per block (wear leveling)
    mounted: bool

  FileHeader = object
    magic: uint32              ## "LFS!" marker (0x53464C21)
    size: uint32
    name: array[32, char]

const
  RamFsMagic = 0x53464C21'u32    ## "LFS!" marker
  BlockCount = 32
  BlockSize = 512
  FileHeaderSize = 40          ## sizeof(FileHeader)

var gLfs: LittleFsState
var gLfsInitDone = false

# =============================================================================
# Flash Device Simulator
# =============================================================================

proc initFlash(fd: var FlashDevice, count, size: int) =
  fd.blockCount = count
  fd.blockSize = size
  fd.storage = newSeq[byte](count * size)
  for i in 0..<fd.storage.len:
    fd.storage[i] = 0xFF'u8

proc flashRead(fd: FlashDevice, blockIdx, offset: int, dest: ptr byte, len: int) =
  let base = blockIdx * fd.blockSize + offset
  let destArr = cast[ptr UncheckedArray[byte]](dest)
  for i in 0..<len:
    destArr[i] = fd.storage[base + i]

proc flashWrite(fd: var FlashDevice, blockIdx, offset: int, src: pointer, len: int) =
  let base = blockIdx * fd.blockSize + offset
  let srcArr = cast[ptr UncheckedArray[byte]](src)
  for i in 0..<len:
    fd.storage[base + i] = fd.storage[base + i] and srcArr[i]

proc flashErase(fd: var FlashDevice, blockIdx: int) =
  let base = blockIdx * fd.blockSize
  for i in 0..<fd.blockSize:
    fd.storage[base + i] = 0xFF'u8

# =============================================================================
# Filesystem Algorithms
# =============================================================================

proc format(self: var LittleFsState) =
  for i in 0..<self.dev.blockCount:
    flashErase(self.dev, i)
    self.eraseCycles[i] = 0

proc initLfsState() =
  if not gLfsInitDone:
    initFlash(gLfs.dev, BlockCount, BlockSize)
    gLfs.eraseCycles = newSeq[int](BlockCount)
    gLfs.format()
    gLfs.mounted = false
    gLfsInitDone = true

proc allocateBlock(self: var LittleFsState): int =
  var minCycles = 99999999
  var bestBlock = -1
  for i in 1..<self.dev.blockCount:
    if self.eraseCycles[i] < minCycles:
      minCycles = self.eraseCycles[i]
      bestBlock = i
  doAssert bestBlock != -1, "ramfs: out of blocks"
  
  flashErase(self.dev, bestBlock)
  inc self.eraseCycles[bestBlock]
  bestBlock

# =============================================================================
# Driver VFS Interface
# =============================================================================

proc ramfsMount(): bool {.nimcall.} =
  initLfsState()
  gLfs.mounted = true
  klog(llInfo, "ramfs: volume mounted")
  true

proc ramfsReadInto(path: cstring; buf: ptr byte; len: int): int {.nimcall.} =
  initLfsState()
  if not gLfs.mounted: return -1
  
  let targetName = $path
  var slotOffset = 0
  while slotOffset + 8 <= gLfs.dev.blockSize:
    var entryMagic: uint32 = 0
    flashRead(gLfs.dev, 0, slotOffset, cast[ptr byte](addr entryMagic), 4)
    if entryMagic == 0xFFFFFFFF'u32:
      break
      
    if entryMagic == RamFsMagic:
      var blockIdx: uint32 = 0
      flashRead(gLfs.dev, 0, slotOffset + 4, cast[ptr byte](addr blockIdx), 4)
      
      var header: FileHeader
      flashRead(gLfs.dev, blockIdx.int, 0, cast[ptr byte](addr header), FileHeaderSize)
      
      var nameStr = ""
      for c in header.name:
        if c == '\0': break
        nameStr.add(c)
        
      if nameStr == targetName:
        let readLen = min(len, header.size.int)
        if readLen > 0:
          flashRead(gLfs.dev, blockIdx.int, FileHeaderSize, buf, readLen)
        return readLen
        
    slotOffset += 8
  -1

proc ramfsWriteFile(path: cstring; data: pointer; len: int): int {.nimcall.} =
  initLfsState()
  if not gLfs.mounted: return -1
  
  let targetName = $path
  if targetName.len > 31: return -1
  
  let blockIdx = gLfs.allocateBlock()
  
  var header = FileHeader(magic: RamFsMagic, size: len.uint32)
  for i in 0..<targetName.len:
    header.name[i] = targetName[i]
  flashWrite(gLfs.dev, blockIdx, 0, addr header, FileHeaderSize)
  
  if len > 0:
    flashWrite(gLfs.dev, blockIdx, FileHeaderSize, data, len)
    
  var slotOffset = 0
  while slotOffset + 8 <= gLfs.dev.blockSize:
    var entryMagic: uint32 = 0
    flashRead(gLfs.dev, 0, slotOffset, cast[ptr byte](addr entryMagic), 4)
    if entryMagic == 0xFFFFFFFF'u32:
      var entryData: array[2, uint32] = [RamFsMagic, blockIdx.uint32]
      flashWrite(gLfs.dev, 0, slotOffset, addr entryData[0], 8)
      return 0
    slotOffset += 8
  -1

proc ramfsDirList(path: cstring; buf: pointer; len: int): int {.nimcall.} =
  initLfsState()
  if not gLfs.mounted: return -1
  
  var listing = ""
  var slotOffset = 0
  
  while slotOffset + 8 <= gLfs.dev.blockSize:
    var entryMagic: uint32 = 0
    flashRead(gLfs.dev, 0, slotOffset, cast[ptr byte](addr entryMagic), 4)
    if entryMagic == 0xFFFFFFFF'u32:
      break
      
    if entryMagic == RamFsMagic:
      var blockIdx: uint32 = 0
      flashRead(gLfs.dev, 0, slotOffset + 4, cast[ptr byte](addr blockIdx), 4)
      
      var header: FileHeader
      flashRead(gLfs.dev, blockIdx.int, 0, cast[ptr byte](addr header), FileHeaderSize)
      
      var nameStr = ""
      for c in header.name:
        if c == '\0': break
        nameStr.add(c)
      
      listing.add(nameStr & "\n")
    slotOffset += 8
    
  if listing.len > 0:
    let writeLen = min(len, listing.len)
    let dest = cast[ptr UncheckedArray[char]](buf)
    for i in 0..<writeLen:
      dest[i] = listing[i]
    return writeLen
  0

proc registerRamFs*() =
  registerDriver(FSDriver(
    name: "ramfs",
    prefix: "/ram/",
    mount: ramfsMount,
    readInto: ramfsReadInto,
    writeFile: ramfsWriteFile,
    dirList: ramfsDirList
  ))
