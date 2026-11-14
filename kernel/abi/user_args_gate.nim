# SPDX-License-Identifier: GPL-2.0
## The kernel's half of the syscall pointer check: which memory is the CALLER's.
## (The rules and the table are in user_args.nim, host-tested.)
import user_args
import ../buffers/kbuffers
import ../handles/khandles
import ../process_table
import ../../mm/region_allocator
import ../../ipc/buffers/types
import ../../core/log

var gRefused: int                                 ## how many calls were refused (log the first few)

proc kernelUserArgsOk*(nr: uint64; a: array[4, uint64]): bool {.nimcall.} =
  khCountCall()                                   # every syscall passes through here exactly once
  let slot = procTable.tasks[procTable.current].regionSlot
  var rlo, rhi: uint64                            # a task with no region owns only buffers
  if slot >= 0:
    rlo = RegionBase + uint64(slot) * RegionSize
    rhi = rlo + RegionSize
  result = userArgsOk(nr, a, rlo, rhi, ArenaBase, ArenaBase + uint64(ArenaSize), kbufAccessible)
  if not result:
    inc gRefused
    if gRefused <= 8:
      klogInt(llWarn, "syscall refused: a pointer leaves the caller's memory, syscall ", int64(nr))
