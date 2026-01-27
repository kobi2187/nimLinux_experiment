# SPDX-License-Identifier: GPL-2.0
## Block device trait - LAYER 0
##
## Defines the interface for block devices (disks, partitions, etc.)

import ../types

type
  # ═══════════════════════════════════════════════════════════════════════════
  # Block I/O Operation Types
  # ═══════════════════════════════════════════════════════════════════════════

  BioOp* = enum
    ## Block I/O operation type
    bioRead      ## Read data from device
    bioWrite     ## Write data to device
    bioFlush     ## Flush device cache
    bioDiscard   ## Discard/trim sectors
    bioSecureErase  ## Secure erase sectors
    bioWriteSame    ## Write same data to range

  BioFlags* = distinct uint32
    ## Flags for block I/O requests

const
  BIO_SYNC*: BioFlags = 1.BioFlags      ## Synchronous I/O
  BIO_FUA*: BioFlags = 2.BioFlags       ## Force unit access
  BIO_PREFLUSH*: BioFlags = 4.BioFlags  ## Pre-flush before I/O
  BIO_NOMERGE*: BioFlags = 8.BioFlags   ## Don't merge with other bios
  BIO_FAILFAST*: BioFlags = 16.BioFlags ## Fail fast on error

proc `or`*(a, b: BioFlags): BioFlags {.inline.} =
  BioFlags(uint32(a) or uint32(b))

proc `and`*(a, b: BioFlags): BioFlags {.inline.} =
  BioFlags(uint32(a) and uint32(b))

type
  # ═══════════════════════════════════════════════════════════════════════════
  # Block I/O Vector
  # ═══════════════════════════════════════════════════════════════════════════

  BioVec* = object
    ## Scatter-gather element for block I/O
    page*: PhysAddr     ## Physical page address
    offset*: uint32     ## Offset within page
    length*: uint32     ## Length in bytes

  # ═══════════════════════════════════════════════════════════════════════════
  # Block I/O Request
  # ═══════════════════════════════════════════════════════════════════════════

  Bio* = ref object
    ## Block I/O request
    op*: BioOp                    ## Operation type
    flags*: BioFlags              ## I/O flags
    sector*: uint64               ## Starting sector
    sectorCount*: uint32          ## Number of sectors

    # Scatter-gather list
    vecs*: ptr UncheckedArray[BioVec]  ## Vector array
    vecCount*: uint16             ## Number of vectors
    vecIndex*: uint16             ## Current vector index

    # Completion
    completion*: proc(bio: Bio, error: int) {.nimcall.}
    private*: pointer             ## For driver use

    # Chaining
    next*: Bio                    ## Next bio in chain

    # Status
    status*: int                  ## Completion status

  # ═══════════════════════════════════════════════════════════════════════════
  # Block Device
  # ═══════════════════════════════════════════════════════════════════════════

  BlockDevice* = ref object of RootObj
    ## Block device representation
    name*: array[32, char]        ## Device name (e.g., "sda")
    major*: uint32                ## Major device number
    minor*: uint32                ## Minor device number

    # Geometry
    capacity*: uint64             ## Total sectors
    sectorSize*: uint32           ## Bytes per sector (usually 512)
    physBlockSize*: uint32        ## Physical block size
    minIoSize*: uint32            ## Minimum I/O size
    optIoSize*: uint32            ## Optimal I/O size

    # Limits
    maxSectors*: uint32           ## Max sectors per request
    maxSegments*: uint16          ## Max scatter-gather segments
    maxSegmentSize*: uint32       ## Max size per segment

    # Operations
    ops*: ptr BlockDeviceOps      ## Device operations

    # Queue
    queue*: pointer               ## Request queue (RequestQueue*)

    # Flags
    readOnly*: bool               ## Read-only device
    removable*: bool              ## Removable media

    # Private
    private*: pointer             ## Driver private data

  BlockDeviceOps* = object
    ## Block device operations
    open*: proc(dev: BlockDevice): Result[void, int] {.nimcall.}
    release*: proc(dev: BlockDevice): Result[void, int] {.nimcall.}
    submit*: proc(dev: BlockDevice, bio: Bio): Result[void, int] {.nimcall.}
    ioctl*: proc(dev: BlockDevice, cmd: uint32, arg: uint64): Result[int, int] {.nimcall.}
    getCapacity*: proc(dev: BlockDevice): uint64 {.nimcall.}
    flush*: proc(dev: BlockDevice): Result[void, int] {.nimcall.}
    discard*: proc(dev: BlockDevice, sector: uint64, count: uint64): Result[void, int] {.nimcall.}

  # ═══════════════════════════════════════════════════════════════════════════
  # Partition Information
  # ═══════════════════════════════════════════════════════════════════════════

  Partition* = object
    ## Disk partition
    startSector*: uint64          ## Starting sector
    sectorCount*: uint64          ## Number of sectors
    partType*: uint8              ## Partition type
    bootable*: bool               ## Bootable flag
    uuid*: array[16, uint8]       ## Partition UUID

# ═══════════════════════════════════════════════════════════════════════════
# Constants
# ═══════════════════════════════════════════════════════════════════════════

const
  SECTOR_SIZE* = 512'u32          ## Standard sector size
  SECTOR_SHIFT* = 9               ## log2(512)

# ═══════════════════════════════════════════════════════════════════════════
# Helper Functions
# ═══════════════════════════════════════════════════════════════════════════

proc bytesToSectors*(bytes: uint64): uint64 {.inline.} =
  ## Convert bytes to sectors
  bytes shr SECTOR_SHIFT

proc sectorsToBytes*(sectors: uint64): uint64 {.inline.} =
  ## Convert sectors to bytes
  sectors shl SECTOR_SHIFT

proc sectorAlignUp*(bytes: uint64): uint64 {.inline.} =
  ## Align bytes up to sector boundary
  alignUp(bytes, SECTOR_SIZE.uint64)

proc sectorAlignDown*(bytes: uint64): uint64 {.inline.} =
  ## Align bytes down to sector boundary
  alignDown(bytes, SECTOR_SIZE.uint64)

proc capacityBytes*(dev: BlockDevice): uint64 {.inline.} =
  ## Get device capacity in bytes
  dev.capacity * dev.sectorSize.uint64

proc getName*(dev: BlockDevice): string =
  ## Get device name as string
  var i = 0
  while i < dev.name.len and dev.name[i] != '\0':
    inc i
  result = newString(i)
  for j in 0..<i:
    result[j] = dev.name[j]
