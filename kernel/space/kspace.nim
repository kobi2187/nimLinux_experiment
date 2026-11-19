# SPDX-License-Identifier: GPL-2.0
## The kernel's address spaces (S8): one master (the kernel's own tables) and one private space per
## ring-3 task, keyed by the task's region slot. The mechanism is mm/addr_space.nim; this module owns
## the static pool (three pages per possible app, so creating a space cannot fail for lack of memory),
## loads a task's tables when it is scheduled, and keeps every space in step with the kernel's mappings.
##
## Lifetime: a space is created before its task exists (the task is born already running on it) and
## destroyed with the task's resources; the region slot is the identity both share.
import ../../mm/addr_space
import ../../mm/region_allocator
import ../../mm/map_generation
import ../process_table
import ../../arch/x86_64/cpu_primitives
import ../../core/log

var
  gPool: array[MaxRegions, SpaceMem]      ## 16 x 12 KB, statically allocated and 4 KB aligned
  gLive: array[MaxRegions, bool]
  gSyncedGen: array[MaxRegions, uint64]   ## the kernel-mapping generation each space has caught up to
  gSerial: array[MaxRegions, uint64]      ## bumped at every creation: tells users of the space it is a new one
  gSerialCounter: uint64
  gKernelCr3*: uint64                     ## the master tables: kernel tasks, and the state between tasks

proc masterTables(): ptr PageTable = cast[ptr PageTable](gKernelCr3)

proc ksSpace*(regionSlot: int): ptr SpaceMem =
  ## The live space of a region slot, or nil.
  if regionSlot < 0 or regionSlot >= MaxRegions or not gLive[regionSlot]: return nil
  addr gPool[regionSlot]

proc ksSerial*(regionSlot: int): uint64 =
  if regionSlot < 0 or regionSlot >= MaxRegions: 0 else: gSerial[regionSlot]

proc ksOfTask*(slot: int): ptr SpaceMem =
  ## The address space a task runs on, nil for kernel tasks.
  if slot < 0 or slot >= process_table.MaxTasks: return nil
  if procTable.tasks[slot].cr3 == 0: return nil
  ksSpace(int(procTable.tasks[slot].regionSlot))

proc ksCreate*(regionSlot: int): uint64 =
  ## Build the space for the app in this region slot: the kernel's mappings, plus its own region as
  ## the only user window. Returns the value for CR3, or 0 if the slot is invalid or already has one.
  if regionSlot < 0 or regionSlot >= MaxRegions or gLive[regionSlot]: return 0
  let sp = addr gPool[regionSlot]
  if not spaceBuild(sp, masterTables()): return 0
  if not spaceGrantWindow(sp, regionBase(RegionHandle(regionSlot)), RegionSize, true): return 0
  # the program's stack lives in the top of its region; the page below it is a guard (an overflow faults at a known address)
  if not spaceGuardPage(sp, regionBase(RegionHandle(regionSlot)) + RegionSize - UserStackReserve): return 0
  gLive[regionSlot] = true
  gSyncedGen[regionSlot] = gKernelMapGen
  inc gSerialCounter
  gSerial[regionSlot] = gSerialCounter
  spaceRoot(sp)

proc ksDestroy*(regionSlot: int) =
  ## The app is gone. If its tables are the ones loaded (it is exiting on its own kernel stack), go
  ## back to the kernel's first; nothing else can still be using them (one CPU).
  let sp = ksSpace(regionSlot)
  if sp == nil: return
  if readCr3() == spaceRoot(sp): writeCr3(gKernelCr3)
  zeroMem(sp, sizeof(SpaceMem))                 # nothing of the dead task's mappings lingers
  gLive[regionSlot] = false

proc syncIfStale(regionSlot: int) =
  if gSyncedGen[regionSlot] != gKernelMapGen:
    spaceSyncKernel(addr gPool[regionSlot], masterTables())
    gSyncedGen[regionSlot] = gKernelMapGen

proc onSwitch(next: int) {.nimcall.} =
  ## Load the incoming task's page tables (the kernel's for a kernel task).
  var want = gKernelCr3
  let sp = ksOfTask(next)
  if sp != nil:
    syncIfStale(int(procTable.tasks[next].regionSlot))
    want = procTable.tasks[next].cr3
  if readCr3() != want: writeCr3(want)

proc onMapChanged() {.nimcall.} =
  ## The kernel's mappings changed while a task may be running: bring ITS space up to date now.
  let cur = int(procTable.current)
  if cur < 0: return
  let sp = ksOfTask(cur)
  if sp == nil: return
  syncIfStale(int(procTable.tasks[cur].regionSlot))
  writeCr3(readCr3())                           # drop stale translations

proc ksInit*() =
  ## Call once the kernel's final page tables are live and before the first ring-3 task is created.
  gKernelCr3 = readCr3()
  onSpaceSwitch = onSwitch
  onKernelMapChanged = onMapChanged
  klog(llInfo, "spaces: per-task address spaces ready")
