# SPDX-License-Identifier: GPL-2.0
## NimixOS Interactive Shell — Slice 1
##
## Serial-based command interpreter. Reads from COM1, echoes input,
## executes built-in commands on Enter. This is the first interactive
## layer of the OS — proves the full kernel stack is working.
##
## To use: connect to QEMU serial with:  make qemu  (reads stdin/stdout)
## Commands: help, version, meminfo, clear, model

import ../core/serial
import ../core/log
import ../mm/physical_manager   # for PhysicalMemManager type
import ../kernel/config          # for KernelModel, IsSasos, IsMicrokernel
import ../runtime/wasm_runner
import ../runtime/wasm_host     # CapIpc, CapEvents
import ../runtime/elf_loader
import ../fs/fatfs
import ../apps/ping/ping_embedded
import ../apps/pingpong/pingpong_embedded
import ../kernel/abi/app_args
import ../arch/x86_64/syscall_gate
import ../mm/region_allocator
import ../mm/sip_heap
import ../kernel/process_table
import ../core/ptr_helpers
import ../drivers/pci/pci_device
import ../drivers/virtio/virtio_net

const
  ShellPrompt = "nimixos> "
  InputMax    = 256

type
  ShellCommand* = enum
    scEmpty
    scUnknown
    scHelp
    scVersion
    scMeminfo
    scClear
    scModel
    scLoadPing      ## load ping — embedded WASM
    scLoadPingpong  ## load pingpong — actor mailbox demo
    scLs            ## ls — list files on disk
    scMount         ## mount — mount FAT disk
    scRun           ## run <file> — load WASM from disk and execute
    scExec          ## exec <file> — load ELF from disk and jump to entry
    scPs            ## ps — list all tasks with pid/class/state/cpu
    scKill          ## kill <pid> — terminate task by PID
    scStats         ## stats — scheduler stats + uptime
    scLspci         ## lspci — list PCI devices
    scNetinfo       ## netinfo — virtio-net MAC and packet counts

# ── String helpers ─────────────────────────────────────────────────────────

proc trimInput(buf: openArray[char], len: int): (int, int) =
  ## Returns (first, last) indices of non-whitespace content in buf[0..<len].
  ## Returns (0, -1) if string is empty or all whitespace.
  var first = 0
  var last  = len - 1
  while first <= last and (buf[first] == ' ' or buf[first] == '\t' or
                           buf[first] == '\n' or buf[first] == '\r'):
    inc first
  while last >= first and (buf[last] == ' ' or buf[last] == '\t' or
                            buf[last] == '\n' or buf[last] == '\r'):
    dec last
  (first, last)

proc bufEq(buf: openArray[char], first, last: int, s: cstring): bool =
  ## Compare buf[first..last] with a cstring without allocating.
  var slen = 0
  while s[slen] != '\0': inc slen
  if last - first + 1 != slen: return false
  for i in 0..<slen:
    if buf[first + i] != s[i]: return false
  true

proc parseCommand*(buf: openArray[char], len: int): ShellCommand =
  ## Parse the input buffer into a ShellCommand without allocating.
  if len == 0: return scEmpty
  let (first, last) = trimInput(buf, len)
  if first > last:  return scEmpty
  if bufEq(buf, first, last, "help"):      return scHelp
  if bufEq(buf, first, last, "version"):   return scVersion
  if bufEq(buf, first, last, "meminfo"):   return scMeminfo
  if bufEq(buf, first, last, "clear"):     return scClear
  if bufEq(buf, first, last, "model"):     return scModel
  if bufEq(buf, first, last, "load ping"):      return scLoadPing
  if bufEq(buf, first, last, "load pingpong"):  return scLoadPingpong
  if bufEq(buf, first, last, "mount"):   return scMount
  if bufEq(buf, first, last, "ls"):    return scLs
  if bufEq(buf, first, last, "ps"):    return scPs
  if bufEq(buf, first, last, "stats"):  return scStats
  if bufEq(buf, first, last, "lspci"):   return scLspci
  if bufEq(buf, first, last, "netinfo"): return scNetinfo
  # "run <file>", "exec <file>", "kill <pid>" — prefix match
  if last - first >= 3 and buf[first] == 'r' and buf[first+1] == 'u' and
     buf[first+2] == 'n' and buf[first+3] == ' ':  return scRun
  if last - first >= 4 and buf[first] == 'e' and buf[first+1] == 'x' and
     buf[first+2] == 'e' and buf[first+3] == 'c' and buf[first+4] == ' ':  return scExec
  if last - first >= 4 and buf[first] == 'k' and buf[first+1] == 'i' and
     buf[first+2] == 'l' and buf[first+3] == 'l' and buf[first+4] == ' ':  return scKill
  scUnknown

# ── Command implementations ────────────────────────────────────────────────

proc cmdHelp() =
  kprint("Commands:\n")
  kprint("  help             - show this message\n")
  kprint("  version          - kernel version and model\n")
  kprint("  meminfo          - physical memory usage\n")
  kprint("  clear            - scroll past old output\n")
  kprint("  model            - current kernel architecture model\n")
  kprint("  mount            - mount FAT disk\n")
  kprint("  load ping        - run embedded ping WASM app\n")
  kprint("  load pingpong    - run embedded pingpong demo\n")
  kprint("  ls               - list files on disk\n")
  kprint("  run <file.wasm>  - load and run WASM from disk\n")
  kprint("  exec <file.elf>  - load and execute ELF from disk\n")
  kprint("  ps               - list all tasks\n")
  kprint("  kill <pid>       - terminate task by PID\n")
  kprint("  stats            - scheduler statistics and uptime\n")
  kprint("  lspci            - list PCI devices\n")
  kprint("  netinfo          - virtio-net MAC and packet counts\n")

proc cmdVersion() =
  kprint("NimixOS v0.1.0\n")

proc cmdModel() =
  kprint("Kernel model: ")
  kprint(KernelModel)
  kprint("\n")
  when IsSasos:
    kprint("  (Single Address Space OS - Singularity-style)\n")
  elif IsMicrokernel:
    kprint("  (Microkernel - hardware-isolated servers)\n")
  else:
    kprint("  (Monolithic - direct in-kernel calls)\n")

proc cmdClear() =
  for i in 0..39: defaultSerial.putChar('\n')

proc cmdMount() =
  if fsMount():
    kprint("Disk mounted\n")
  else:
    kprint("Mount failed\n")

proc kprintKV(label: string; value: int64; unit: string) =
  kprint(label); kprintInt(value); kprint(unit)

proc cmdMeminfo(physMgr: PhysicalMemManager) =
  if physMgr == nil:
    kprint("Memory manager not available\n")
    return
  let totalMB = int64(physMgr.totalFrames) * 4096 div (1024 * 1024)
  let usedMB  = int64(physMgr.usedFrames)  * 4096 div (1024 * 1024)
  let freeMB  = totalMB - usedMB
  kprint("Physical memory:\n")
  kprintKV("  Total: ", totalMB, " MB\n")
  kprintKV("  Used:  ", usedMB,  " MB\n")
  kprintKV("  Free:  ", freeMB,  " MB\n")

proc printHex4(val: uint16) {.inline.} =
  defaultSerial.putHex(uint64(val), 4)

proc printHex2(val: uint8) {.inline.} =
  defaultSerial.putHex(uint64(val), 2)

proc cmdNetinfo() =
  if not gVirtioNetReady:
    kprint("virtio-net: not available\n")
    return
  var infoBuf: array[128, char]
  let n = virtioNetInfo(addr infoBuf[0], infoBuf.len)
  for i in 0..<n: defaultSerial.putChar(infoBuf[i])

proc cmdLspci() =
  pciScan()
  if gPciCount == 0:
    kprint("No PCI devices found.\n")
    return
  for i in 0..<gPciCount:
    let d = gPciDevices[i]
    kprint("[")
    printHex2(d.bus); kprint(":")
    printHex2(d.slot); kprint(".")
    defaultSerial.putHex(uint64(d.fn), 1)
    kprint("] ")
    printHex4(d.vendorId); kprint(":")
    printHex4(d.deviceId); kprint(" ")
    let name = pciDeviceName(d.vendorId, d.deviceId)
    if name != nil:
      defaultSerial.putString(name)
    else:
      kprint("unknown")
    kprint(" (class ")
    printHex2(d.classCode); kprint(" sub ")
    printHex2(d.subclass); kprint(")\n")


# Static buffer for disk-loaded files (512 KB)
var diskFileBuf: array[512 * 1024, byte]

proc cmdRun(filename: cstring) =
  ## Load a .wasm file from disk and execute it.
  if not fsMounted and not fsMount():
    kprint("No disk available\n")
    return
  kprint("Loading ")
  defaultSerial.putString(filename)
  kprint("...\n")
  let (res, nbytes) = fsReadInto(filename,
                                  cast[ptr byte](addr diskFileBuf[0]),
                                  diskFileBuf.len)
  if res != fOk:
    kprint("File read failed\n")
    return
  kprintInt(int64(nbytes))
  kprint(" bytes read\n")
  let caps = [CapIpc, CapEvents]
  let r = wasmRun(cast[ptr byte](addr diskFileBuf[0]), nbytes, caps)
  if r != wasmOk:
    kprint("WASM execution failed\n")

proc buildAbiPatches(): array[20, AbiPatch] =
  ## Build the ABI patch table — each entry maps a weak stub name to its
  ## NimixSyscall ordinal. The ELF loader overwrites stubs with
  ## `movabs rax, <nr>; syscall` so apps issue the right syscall number.
  proc p(name: cstring; nr: uint64): AbiPatch = AbiPatch(name: name, nr: nr)
  result[0]  = p("nimixWrite",          ord(scWrite).uint64)
  result[1]  = p("nimixExit",           ord(scExit).uint64)
  result[2]  = p("nimixAllocRegion",    ord(scAllocRegion).uint64)
  result[3]  = p("nimixFreeRegion",     ord(scFreeRegion).uint64)
  result[4]  = p("nimixChanSend",       ord(scChanSend).uint64)
  result[5]  = p("nimixChanRecv",       ord(scChanRecv).uint64)
  result[6]  = p("nimixEventPublish",   ord(scEventPublish).uint64)
  result[7]  = p("nimixEventSubscribe", ord(scEventSubscribe).uint64)
  result[8]  = p("nimixEventPoll",      ord(scEventPoll).uint64)
  result[9]  = p("nimixGetArgs",        ord(scGetArgs).uint64)
  result[10] = p("nimixProcList",       ord(scProcList).uint64)
  result[11] = p("nimixSchedStats",     ord(scSchedStats).uint64)
  result[12] = p("nimixProcKillPid",    ord(scProcKillPid).uint64)
  result[13] = p("nimixFsReadDir",      ord(scFsReadDir).uint64)
  result[14] = p("nimixFsRead",         ord(scFsRead).uint64)
  result[15] = p("nimixFsWrite",        ord(scFsWrite).uint64)
  result[16] = p("nimixUptimeSecs",     ord(scUptimeSecs).uint64)
  result[17] = p("nimixWallClock",      ord(scWallClock).uint64)
  result[18] = p("nimixMapAnon",        ord(scMapAnon).uint64)
  result[19] = p("nimixFreeAnon",       ord(scFreeAnon).uint64)

proc runPieElf(filename: cstring; dataBuf: ptr byte; nbytes: int; appArgs: cstring) =
  ## Load and run a PIE (ET_DYN) ELF. Allocates a region, patches ABI stubs,
  ## runs appMain, then frees the region.
  let slot = regionAlloc(RegionSize)
  if not regionValid(slot):
    kprint("No free region slots\n"); return
  let base = regionBase(slot)
  klogInt(llInfo, "ELF PIE: region base=0x", int64(base))

  var patches = buildAbiPatches()
  let loaded = elfLoadPie(dataBuf, nbytes, base,
                          cast[ptr UncheckedArray[AbiPatch]](addr patches[0]),
                          patches.len)
  if loaded.err != elfOk:
    kprint("PIE ELF load failed\n"); regionFree(slot); return
  if loaded.appMain == 0:
    kprint("appMain not found in PIE ELF\n"); regionFree(slot); return

  # Initialise the SIP heap for this region slot, placing bump after the ELF.
  sipHeapInit(int(slot))
  if loaded.loadEnd > 0:
    sipHeapSetBump(int(slot), loaded.loadEnd)

  # User stack: top 64 KB of the 4 MB region (above ELF + heap).
  let userStackTop = base + RegionSize - 16
  setAppArgs(int(slot), appArgs)
  let procSlot = procSpawnRing3(filename, loaded.appMain, userStackTop, int32(slot))
  if procSlot < 0:
    kprint("procSpawnRing3 failed\n"); regionFree(slot); return
  kprint("App spawned in ring 3\n")
  # Shell returns immediately; app runs in parallel via the preemptive scheduler.
  # Region and task slot are freed by abiExit when the app calls nimixExit().

proc launchElfBytes*(filename: cstring; dataBuf: ptr byte; nbytes: int; args: cstring = nil) =
  ## Load and spawn a PIE ELF from an in-memory buffer. Public — used by testMode.
  runPieElf(filename, dataBuf, nbytes, args)

proc runExecElf(dataBuf: ptr byte; nbytes: int) =
  ## Load and run a non-PIE (ET_EXEC) ELF at its fixed vaddr.
  let loaded = elfLoad(dataBuf, nbytes)
  if loaded.err != elfOk:
    kprint("ELF load failed\n"); return
  kprint("Jumping to ELF entry...\n")
  cast[proc() {.nimcall.}](loaded.entry)()

proc cmdExec(filename: cstring; appArgs: cstring = nil) =
  ## Load an ELF binary from disk and execute it.
  ## Detects PIE (ET_DYN) vs non-PIE (ET_EXEC) and dispatches accordingly.
  if not fsMounted and not fsMount():
    kprint("No disk available\n"); return
  kprint("Loading ELF: ")
  defaultSerial.putString(filename)
  kprint("...\n")
  let (res, nbytes) = fsReadInto(filename,
                                  cast[ptr byte](addr diskFileBuf[0]),
                                  diskFileBuf.len)
  if res != fOk:
    kprint("File read failed\n"); return
  let dataBuf = cast[ptr byte](addr diskFileBuf[0])
  if isPieElf(dataBuf):
    runPieElf(filename, dataBuf, nbytes, appArgs)
  else:
    runExecElf(dataBuf, nbytes)

# ── Argument extraction ────────────────────────────────────────────────────

proc extractArg[N: static int](buf: openArray[char]; first, last, skip: int;
                                dst: var array[N, char]) =
  ## Copy the token after `skip` bytes from `first` into `dst`, NUL-terminated.
  var si = first + skip
  while si <= last and buf[si] == ' ': inc si
  var di = 0
  while si <= last and di < N - 1:
    dst[di] = buf[si]; inc di; inc si
  dst[di] = '\0'

# ── App exec helper ────────────────────────────────────────────────────────

proc execApp(name: cstring; args: cstring) =
  ## Load a PIE ELF app from disk with given args string.
  cmdExec(name, args)

proc cmdUnknown(buf: openArray[char], first, last: int) =
  ## Try to execute as filename from disk. Detect .elf vs .wasm.
  if not fsMounted and not fsMount():
    kprint("No disk mounted\n")
    return

  var fname: array[128, char]
  var flen = 0
  var i = first
  while i <= last and flen < 127:
    if buf[i] == ' ': break
    fname[flen] = buf[i]
    inc flen
    inc i
  fname[flen] = '\0'

  let isElf = flen > 4 and fname[flen-4] == '.' and fname[flen-3] == 'e' and
              fname[flen-2] == 'l' and fname[flen-1] == 'f'
  let isWasm = flen > 5 and fname[flen-5] == '.' and fname[flen-4] == 'w' and
               fname[flen-3] == 'a' and fname[flen-2] == 's' and fname[flen-1] == 'm'

  if isElf:
    cmdExec(cast[cstring](addr fname[0]))
  elif isWasm:
    cmdRun(cast[cstring](addr fname[0]))
  else:
    kprint("Unknown command: '")
    for j in first..last: defaultSerial.putChar(buf[j])
    kprint("' (not .elf or .wasm)\n")

# ── Shell input helpers ────────────────────────────────────────────────────

proc resetBuf(buf: var array[InputMax, char]; len: var int) =
  for i in 0..<len: buf[i] = '\0'
  len = 0

proc handleBackspace(buf: var array[InputMax, char]; len: var int) =
  if len == 0: return
  dec len; buf[len] = '\0'
  defaultSerial.putChar('\b'); defaultSerial.putChar(' '); defaultSerial.putChar('\b')

proc handleChar(buf: var array[InputMax, char]; len: var int; c: char) =
  if len >= InputMax - 1: return
  buf[len] = c; inc len; defaultSerial.putChar(c)

proc wasmLog(verb, label: string) =
  kprint("[wasm] "); kprint(verb); kprint(" "); kprint(label); kprint("\n")

proc runWasm(label: string; data: ptr byte; len: int) =
  wasmLog("loading", label)
  if wasmRun(data, len) != wasmOk: wasmLog("error running", label)

proc runWasmWithCaps(label: string; data: ptr byte; len: int) =
  wasmLog("loading", label)
  let caps = [CapIpc, CapEvents]
  if wasmRun(data, len, caps) != wasmOk: wasmLog("error running", label)

proc execArg[N: static int](buf: openArray[char]; first, last, skip: int; app: cstring) =
  var dst: array[N, char]
  extractArg(buf, first, last, skip, dst)
  execApp(app, cast[cstring](addr dst[0]))

proc dispatchCmd(cmd: ShellCommand; buf: openArray[char];
                 first, last: int; physMgr: PhysicalMemManager) =
  case cmd
  of scHelp:        cmdHelp()
  of scVersion:     cmdVersion()
  of scMeminfo:     cmdMeminfo(physMgr)
  of scClear:       cmdClear()
  of scModel:       cmdModel()
  of scMount:       cmdMount()
  of scLoadPing:
    runWasm("ping",    cast[ptr byte](unsafeAddr pingWasm[0]),     pingWasm.len)
  of scLoadPingpong:
    runWasmWithCaps("pingpong", cast[ptr byte](unsafeAddr pingpongWasm[0]), pingpongWasm.len)
  of scLs:     execApp("ls.elf", "/")
  of scPs:     execApp("ps.elf", "")
  of scStats:  execApp("stats.elf", "")
  of scLspci:  cmdLspci()
  of scNetinfo: cmdNetinfo()
  of scRun:
    var fname: array[128, char]
    extractArg(buf, first, last, 4, fname); cmdRun(cast[cstring](addr fname[0]))
  of scExec:
    var fname: array[128, char]
    extractArg(buf, first, last, 5, fname); cmdExec(cast[cstring](addr fname[0]))
  of scKill:
    var pidBuf: array[32, char]
    extractArg(buf, first, last, 5, pidBuf); execApp("kill.elf", cast[cstring](addr pidBuf[0]))
  of scEmpty:   discard
  of scUnknown: cmdUnknown(buf, first, last)

proc handleEnter(buf: var array[InputMax, char]; len: var int;
                 physMgr: PhysicalMemManager) =
  defaultSerial.putChar('\n')
  let cmd = parseCommand(buf, len)
  let (first, last) = trimInput(buf, len)
  dispatchCmd(cmd, buf, first, last, physMgr)
  resetBuf(buf, len)
  kprint(ShellPrompt)

# ── Main shell loop ────────────────────────────────────────────────────────

proc printBanner() =
  kprint("\n========================================\n")
  kprint("  Welcome to NimixOS\n")
  kprint("  Type 'help' for available commands.\n")
  kprint("========================================\n\n")

proc runShell*(physMgr: PhysicalMemManager) =
  klog(llInfo, "Entering shell")
  printBanner()
  var inputBuf: array[InputMax, char]
  var inputLen = 0
  kprint(ShellPrompt)
  while true:
    let c = defaultSerial.getChar()
    case c
    of '\r', '\n':       handleEnter(inputBuf, inputLen, physMgr)
    of '\b', char(127):  handleBackspace(inputBuf, inputLen)
    else:                handleChar(inputBuf, inputLen, c)
