# SPDX-License-Identifier: GPL-2.0
## Starting programs (S3): the one place that turns an ELF image into a ring-3 task, and the
## `spawn` syscall on top of it.
##
## Authority (docs/proposals/capabilities.md §3.5): a task can start another only by presenting a
## PROCESS handle with the spawn right; the child's whole world is the handles listed in the call,
## each one MOVED out of the spawner's table (conservation: only what the spawner holds, never wider
## than it holds, and it must be transferable). The i-th listed handle arrives in the child's table
## as `BootstrapHandle + i`. There is no ambient name, topic or global: a program given nothing can
## do nothing, and one not given a process handle cannot start another.
##
## The launcher POLICY (which handles an app gets) is not here: it is data the launcher program
## reads (launch/manifest.nim) and turns into a grant list. This module only enforces conservation.
##
## Errors: 0/pid on success; -1 bad handle or argument (the same code the channel calls use);
## -30 file not found; -31 not a loadable image; -32 out of regions, spaces or tasks; -33 busy.
import ../../ipc/handles/handle_table
import ../handles/khandles
import ../process_table
import ../space/kspace
import ../abi/app_args
import ../../runtime/elf_loader
import ../../arch/x86_64/syscall_gate
import ../../arch/x86_64/cpu_primitives
import ../../mm/region_allocator
import ../../mm/sip_heap
import ../../fs/fatfs
import ../../core/log
import ../../launch/manifest

const
  SpawnGrantMax* = 8
  SpawnReqBytes* = 4 + 4 * SpawnGrantMax + 4 * SpawnGrantMax   ## kernel/abi/user_args.nim checks this size
  ErrNotFound* = -30
  ErrBadImage* = -31
  ErrNoResource* = -32
  ErrBusy* = -33
  ImageMax = 512 * 1024

type
  SpawnReq* {.packed.} = object
    n*: uint32
    handle*: array[SpawnGrantMax, uint32]
    rights*: array[SpawnGrantMax, uint32]       ## what the child gets of each (a subset of what the spawner holds)

  Grant* = object
    h*: Handle
    rights*: Rights

static: doAssert sizeof(SpawnReq) == SpawnReqBytes

var
  gImage: array[ImageMax, byte]       ## the file being started by a syscall (the shell has its own)
  gImageBusy: bool
  gLastSlot*: int = -1                ## the task slot and region slot of the last program started
  gLastRegion*: int = -1

proc buildAbiPatches(): array[NimixSyscallCount, AbiPatch] =
  ## Every syscall's weak stub name mapped to its ordinal, from the single NimixSyscallSymbol table.
  for sc in NimixSyscall:
    result[ord(sc)] = AbiPatch(name: NimixSyscallSymbol[sc], nr: ord(sc).uint64)

proc grantsOk(spawner: int; grants: openArray[Grant]): bool =
  ## Every listed handle is live in the spawner's table, transferable, listed once, and the child's
  ## rights do not exceed the spawner's. Checked BEFORE anything is created, so a refusal changes nothing.
  for i in 0 ..< grants.len:
    var kind: ObjKind
    var o: ObjId
    var held: Rights
    var badge: uint64
    if hsLookupAny(gHs, spawner, grants[i].h, rtTransfer, kind, o, held, badge) != heOk: return false
    if not grants[i].rights.subsetOf(held): return false
    for j in 0 ..< i:
      if grants[j].h == grants[i].h: return false
  true

proc spawnPie*(spawner: int; name: cstring; image: ptr byte; nbytes: int; args: cstring;
               grants: openArray[Grant]): int =
  ## Load a PIE ELF into a fresh region and its own address space and start it as a ring-3 task, with
  ## `grants` moved from `spawner`'s table. Returns the new pid, or a negative error.
  if not grantsOk(spawner, grants): return -1
  let slot = regionAlloc(RegionSize)
  if not regionValid(slot): return ErrNoResource
  let base = regionBase(slot)
  var patches = buildAbiPatches()
  let loaded = elfLoadPie(image, nbytes, base,
                          cast[ptr UncheckedArray[AbiPatch]](addr patches[0]), patches.len)
  if loaded.err != elfOk or loaded.appMain == 0:
    regionFree(slot); return ErrBadImage
  sipHeapInit(int(slot))
  if loaded.loadEnd > 0: sipHeapSetBump(int(slot), loaded.loadEnd)
  setAppArgs(int(slot), args)
  let cr3 = ksCreate(int(slot))
  if cr3 == 0:
    regionFree(slot); return ErrNoResource
  # the grants must land before the child can run: no preemption between creating it and granting
  let irq = disableInterrupts()
  let procSlot = procSpawnRing3(name, loaded.appMain, base + RegionSize - 16, int32(slot), cr3)
  if procSlot >= 0:
    for g in grants:
      if not khGrant(spawner, g.h, procSlot, g.rights): klog(llError, "spawn: a checked grant failed")
  restoreInterrupts(irq)
  if procSlot < 0:
    ksDestroy(int(slot)); regionFree(slot); return ErrNoResource
  gLastSlot = procSlot
  gLastRegion = int(slot)
  int(procTable.tasks[procSlot].pid)

proc khNewLauncher*(task: int): Handle =
  ## A process handle with the spawn right (and the right to hand it on) for `task`. Only trusted
  ## boot code calls this: it is where spawn authority enters the system.
  discard hsAttach(gHs, task)
  var o: ObjId
  if hsNewObject(gHs, okProcess, 0, o) != heOk: return NoHandle
  var h: Handle
  if hsInstall(gHs, task, o, rtSpawn or rtTransfer or rtDuplicate, 0, h) != heOk:
    hsDiscardObject(gHs, o)
    return NoHandle
  h

var
  gManBuf: array[2048, char]
  gPolBuf: array[2048, char]

proc readSmall(path: cstring; buf: var array[2048, char]): int =
  ## A small text file, or -1 (missing, unreadable or too big).
  if not fsMounted and not fsMount(): return -1
  let (res, n) = fsReadInto(path, cast[ptr byte](addr buf[0]), buf.len)
  if res != fOk: -1 else: n

proc manifestGrants*(spawner: int; launcherH: Handle; program: cstring;
                     grants: var array[SpawnGrantMax, Grant]): int =
  ## The launcher's policy step: the handles this program is given, from `<program>.mf` (what it asks
  ## for) and `system.pol` (what the machine allows). Only the intersection is granted; a missing or
  ## invalid file grants nothing. Returns how many entries of `grants` are filled. Names that have no
  ## object yet (display, input, files, net, dispatcher) are reported and skipped: they are resolved
  ## by the slices that create those objects.
  var path: array[128, char]
  var n = 0
  while program[n] != '\0' and n < 120: path[n] = program[n]; inc n
  var dot = n
  for i in 0 ..< n:
    if path[i] == '.': dot = i                         # strip the last extension
  for (c, k) in [('.', 0), ('m', 1), ('f', 2)]: path[dot + k] = c
  path[dot + 3] = '\0'
  let mn = readSmall(cast[cstring](addr path[0]), gManBuf)
  let pn = readSmall("system.pol", gPolBuf)
  let man = if mn > 0: parseManifest(gManBuf.toOpenArray(0, mn - 1)) else: ParseResult(ok: true)
  let pol = if pn > 0: parsePolicy(gPolBuf.toOpenArray(0, pn - 1)) else: ParseResult(ok: true)
  if mn > 0 and not man.ok: klogInt(llWarn, "launcher: invalid manifest, line ", int64(man.line))
  if pn > 0 and not pol.ok: klogInt(llWarn, "launcher: invalid system.pol, line ", int64(pol.line))
  let eff = effectiveGrants(man, pol)
  var line = "launcher: " & $program & " grants:"
  for g in GrantName:
    if g notin eff: continue
    if g == gnSpawn:
      var dup: Handle
      if launcherH != NoHandle and hsDuplicate(gHs, spawner, launcherH, rtSpawn, dup) == heOk:
        grants[result] = Grant(h: dup, rights: rtSpawn); inc result
        line.add " " & nameOf(g)
    else:
      line.add " (" & nameOf(g) & " not available yet)"
  if result == 0 and line[^1] == ':': line.add " none"
  klog(llInfo, line)

proc abiSpawn*(launcher: uint32; path: cstring; args: cstring; req: pointer): int {.nimcall.} =
  ## spawn(launcher, path, args, req): start the PIE ELF at `path` with the handles listed in `req`.
  let me = khMe()
  if me < 0: return -1
  var o: ObjId
  var badge: uint64
  if hsLookup(gHs, me, Handle(launcher), okProcess, rtSpawn, o, badge) != heOk: return -1
  let q = cast[ptr SpawnReq](req)[]
  if q.n > uint32(SpawnGrantMax): return -1
  var grants: array[SpawnGrantMax, Grant]
  for i in 0 ..< int(q.n): grants[i] = Grant(h: Handle(q.handle[i]), rights: Rights(q.rights[i]))
  if gImageBusy: return ErrBusy
  gImageBusy = true
  defer: gImageBusy = false
  if not fsMounted and not fsMount(): return ErrNotFound
  let (res, nbytes) = fsReadInto(path, addr gImage[0], ImageMax)
  if res != fOk: return ErrNotFound
  spawnPie(me, path, addr gImage[0], nbytes, args, grants.toOpenArray(0, int(q.n) - 1))
