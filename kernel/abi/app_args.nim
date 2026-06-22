# SPDX-License-Identifier: GPL-2.0
## Per-region-slot args store.
##
## The shell writes args here before calling appMain(); the ABI getArgs
## handler reads from the current task's slot.  No aliasing: each slot
## has its own 256-byte buffer in kernel BSS.

const
  MaxArgsLen* = 256
  MaxRegions  = 16

var gRegionArgs*: array[MaxRegions, array[MaxArgsLen, char]]

proc setAppArgs*(slot: int; args: cstring) =
  ## Write a NUL-terminated args string into the slot's buffer.
  for i in 0 ..< MaxArgsLen: gRegionArgs[slot][i] = '\0'
  if args == nil or args[0] == '\0': return
  var i = 0
  while i < MaxArgsLen - 1 and args[i] != '\0':
    gRegionArgs[slot][i] = args[i]
    inc i

proc getAppArgs*(slot: int; buf: pointer; bufLen: int): int =
  ## Copy the slot's args string into buf.  Returns bytes written (excl. NUL).
  if slot < 0 or slot >= MaxRegions: return -1
  let dst = cast[ptr UncheckedArray[char]](buf)
  var i = 0
  while i < bufLen - 1 and gRegionArgs[slot][i] != '\0':
    dst[i] = gRegionArgs[slot][i]
    inc i
  dst[i] = '\0'
  i
