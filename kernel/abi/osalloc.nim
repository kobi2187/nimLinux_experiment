# SPDX-License-Identifier: GPL-2.0
# NimixOS allocator shim for --os:nimix target.
# Provides allocMem/deallocMem/reallocMem used by Nim's ARC runtime.

when defined(testing):
  proc nimixAllocRegion(size: int): pointer = alloc(size)
  proc nimixFreeRegion(p: pointer; size: int) = dealloc(p)
else:
  proc nimixAllocRegion(size: int): pointer {.importc, cdecl.}
  proc nimixFreeRegion(p: pointer; size: int) {.importc, cdecl.}

proc allocMem*(size: Natural): pointer =
  nimixAllocRegion(int(size))

proc deallocMem*(p: pointer; size: Natural) =
  nimixFreeRegion(p, int(size))

proc reallocMem*(p: pointer; oldSize: Natural; newSize: Natural): pointer =
  ## Simple realloc: alloc new, copy, free old.
  ## Not efficient but correct for now.
  result = nimixAllocRegion(int(newSize))
  if result == nil: return
  if p != nil:
    let copyLen = if oldSize < newSize: oldSize else: newSize
    let src = cast[ptr UncheckedArray[byte]](p)
    let dst = cast[ptr UncheckedArray[byte]](result)
    for i in 0 ..< copyLen: dst[i] = src[i]
    nimixFreeRegion(p, int(oldSize))

proc getOccupiedMem*(): int = 0
proc getFreeMem*(): int = 0
proc getTotalMem*(): int = 0
