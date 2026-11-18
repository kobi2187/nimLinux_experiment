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
import ../mm/user_window
import devtest
import ../core/klog_ring
import ../kernel/console/console_input
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
    scMount         ## mount — mount FAT disk
    scRun           ## run <file> — load WASM from disk and execute
    scExec          ## exec <file> — load ELF from disk and jump to entry
    scLspci         ## lspci — list PCI devices
    scNetinfo       ## netinfo — virtio-net MAC and packet counts
    scDmesg         ## dmesg — kernel log ring (boot + driver messages)
    scDevtest       ## devtest <gpu|snd|net|input> — exercise a virtio device

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
  if bufEq(buf, first, last, "dmesg"):     return scDmesg
  if bufEq(buf, first, last, "model"):     return scModel
  if bufEq(buf, first, last, "load ping"):      return scLoadPing
  if bufEq(buf, first, last, "load pingpong"):  return scLoadPingpong
  if bufEq(buf, first, last, "mount"):   return scMount
  if bufEq(buf, first, last, "lspci"):   return scLspci
  if bufEq(buf, first, last, "netinfo"): return scNetinfo
  if last - first >= 7 and bufEq(buf, first, first + 7, "devtest "): return scDevtest
  if bufEq(buf, first, last, "devtest"): return scDevtest
  # "run <file>", "exec <file>", "kill <pid>" — prefix match
  if last - first >= 3 and buf[first] == 'r' and buf[first+1] == 'u' and
     buf[first+2] == 'n' and buf[first+3] == ' ':  return scRun
  if last - first >= 4 and buf[first] == 'e' and buf[first+1] == 'x' and
     buf[first+2] == 'e' and buf[first+3] == 'c' and buf[first+4] == ' ':  return scExec
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
  kprint("  <name> [args]    - run name / name.elf (system, servers) / name.wasm (apps)\n")
  kprint("                     e.g. ls /, ps, top, stats, kill <pid>, hello\n")
  kprint("  run <file.wasm>  - load and run WASM from disk\n")
  kprint("  exec <file.elf>  - load and execute ELF from disk\n")
  kprint("  lspci            - list PCI devices\n")
  kprint("  netinfo          - virtio-net MAC and packet counts\n")
  kprint("  dmesg            - kernel log (last 16 KB of klog output)\n")
  kprint("  devtest <dev>    - exercise gpu|snd|net|input (host-verifiable)\n")

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

proc cmdDmesg() =
  if klogRingDropped() > 0:
    kprint("[... "); kprintInt(int64(klogRingDropped())); kprint(" earlier bytes dropped]\n")
  for c in klogRingChars(): defaultSerial.putChar(c)

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

proc buildAbiPatches(): array[NimixSyscallCount, AbiPatch] =
  ## Build the ABI patch table — every syscall's weak stub name mapped to its
  ## NimixSyscall ordinal, from the single NimixSyscallSymbol table. The ELF
  ## loader overwrites stubs with `movabs rax, <nr>; syscall`. (A hand-kept
  ## list here once covered 20 of 28 calls: nimixSleep/Yield silently no-op'd.)
  for sc in NimixSyscall:
    result[ord(sc)] = AbiPatch(name: NimixSyscallSymbol[sc], nr: ord(sc).uint64)

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
  if not appRegionUserAccess(slot, true):
    kprint("Region not user-mappable\n"); regionFree(slot); return
  let procSlot = procSpawnRing3(filename, loaded.appMain, userStackTop, int32(slot))
  if procSlot < 0:
    discard appRegionUserAccess(slot, false)
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

proc loadFile(name: cstring): int =
  ## Read a disk file into diskFileBuf without printing. Bytes read, or -1.
  if not fsMounted and not fsMount(): return -1
  let (res, n) = fsReadInto(name, cast[ptr byte](addr diskFileBuf[0]),
                            diskFileBuf.len)
  if res != fOk: -1 else: n

proc launchLoaded(name: cstring; nbytes: int; args: cstring) =
  ## Start what diskFileBuf holds, chosen by magic — not by extension:
  ## ELF  = system tool or server (its own ring-3 task),
  ## WASM = regular app (sandboxed; only the capabilities it is given).
  let p = cast[ptr UncheckedArray[byte]](addr diskFileBuf[0])
  if nbytes >= 4 and p[0] == 0x7f'u8 and p[1] == byte('E') and
     p[2] == byte('L') and p[3] == byte('F'):
    let dataBuf = cast[ptr byte](addr diskFileBuf[0])
    if isPieElf(dataBuf): runPieElf(name, dataBuf, nbytes, args)
    else: runExecElf(dataBuf, nbytes)
  elif nbytes >= 4 and p[0] == 0'u8 and p[1] == byte('a') and
       p[2] == byte('s') and p[3] == byte('m'):
    let caps = [CapIpc, CapEvents]
    wasmSetArgs(args)
    if wasmRun(cast[ptr byte](addr diskFileBuf[0]), nbytes, caps) != wasmOk:
      kprint("WASM execution failed\n")
  else:
    kprint("not an ELF or WASM file\n")

proc withSuffix(dst: var array[128, char]; name: openArray[char]; n: int;
                suffix: string) =
  ## dst = name[0..<n] & suffix, NUL-terminated (no heap).
  var k = 0
  while k < n and k < dst.len - suffix.len - 1:
    dst[k] = name[k]; inc k
  for c in suffix:
    dst[k] = c; inc k
  dst[k] = '\0'

proc cmdUnknown(buf: openArray[char], first, last: int) =
  ## `name [args]`: run a program from disk. Tries `name` as given, then
  ## `name.elf` (system tools + servers), then `name.wasm` (regular apps).
  var word: array[128, char]
  var n = 0
  var i = first
  while i <= last and buf[i] != ' ' and n < 100:
    word[n] = buf[i]; inc n; inc i
  var args: array[128, char]
  extractArg(buf, i, last, 0, args)
  var cand: array[128, char]
  for suffix in ["", ".elf", ".wasm"]:
    withSuffix(cand, word, n, suffix)
    let nbytes = loadFile(cast[cstring](addr cand[0]))
    if nbytes >= 0:
      launchLoaded(cast[cstring](addr cand[0]), nbytes,
                   cast[cstring](addr args[0]))
      return
  kprint("Unknown command: '")
  for j in first..last: defaultSerial.putChar(buf[j])
  kprint("' (no such program, .elf or .wasm)\n")

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

proc dispatchCmd(cmd: ShellCommand; buf: openArray[char];
                 first, last: int; physMgr: PhysicalMemManager) =
  case cmd
  of scHelp:        cmdHelp()
  of scVersion:     cmdVersion()
  of scMeminfo:     cmdMeminfo(physMgr)
  of scClear:       cmdClear()
  of scDmesg:       cmdDmesg()
  of scModel:       cmdModel()
  of scMount:       cmdMount()
  of scLoadPing:
    runWasm("ping",    cast[ptr byte](unsafeAddr pingWasm[0]),     pingWasm.len)
  of scLoadPingpong:
    runWasmWithCaps("pingpong", cast[ptr byte](unsafeAddr pingpongWasm[0]), pingpongWasm.len)
  of scLspci:  cmdLspci()
  of scNetinfo: cmdNetinfo()
  of scDevtest:
    var dev: array[16, char]
    extractArg(buf, first, last, 7, dev); devtest(dev)
  of scRun:
    var fname: array[128, char]
    extractArg(buf, first, last, 4, fname); cmdRun(cast[cstring](addr fname[0]))
  of scExec:
    var fname: array[128, char]
    extractArg(buf, first, last, 5, fname); cmdExec(cast[cstring](addr fname[0]))
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
    let c = consoleGetChar()         # serial or keyboard; flushes the display
    case c
    of '\r', '\n':       handleEnter(inputBuf, inputLen, physMgr)
    of '\b', char(127):  handleBackspace(inputBuf, inputLen)
    else:                handleChar(inputBuf, inputLen, c)
