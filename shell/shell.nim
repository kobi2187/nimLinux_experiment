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
import ../kernel/abi/nimix_abi as abiModule
import ../kernel/abi/app_args
import ../mm/region_allocator
import ../kernel/process_table

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
    scRun           ## run <file> — load WASM from disk and execute
    scExec          ## exec <file> — load ELF from disk and jump to entry
    scPs            ## ps — list all tasks with pid/class/state/cpu
    scKill          ## kill <pid> — terminate task by PID
    scStats         ## stats — scheduler stats + uptime

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
  if bufEq(buf, first, last, "ls"):    return scLs
  if bufEq(buf, first, last, "ps"):    return scPs
  if bufEq(buf, first, last, "stats"): return scStats
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
  kprint("  load ping        - run embedded ping WASM app\n")
  kprint("  load pingpong    - run embedded pingpong demo\n")
  kprint("  ls               - list files on disk\n")
  kprint("  run <file.wasm>  - load and run WASM from disk\n")
  kprint("  exec <file.elf>  - load and execute ELF from disk\n")
  kprint("  ps               - list all tasks\n")
  kprint("  kill <pid>       - terminate task by PID\n")
  kprint("  stats            - scheduler statistics and uptime\n")

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

proc cmdMeminfo(physMgr: PhysicalMemManager) =
  if physMgr == nil:
    kprint("Memory manager not available\n")
    return
  let totalMB = int64(physMgr.totalFrames) * 4096 div (1024 * 1024)
  let usedMB  = int64(physMgr.usedFrames)  * 4096 div (1024 * 1024)
  let freeMB  = totalMB - usedMB
  kprint("Physical memory:\n")
  kprint("  Total: "); kprintInt(totalMB); kprint(" MB\n")
  kprint("  Used:  "); kprintInt(usedMB);  kprint(" MB\n")
  kprint("  Free:  "); kprintInt(freeMB);  kprint(" MB\n")

proc cmdUnknown(buf: openArray[char], first, last: int) =
  kprint("Unknown command: '")
  for i in first..last: defaultSerial.putChar(buf[i])
  kprint("'\nType 'help' for available commands.\n")


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

proc cmdExec(filename: cstring; appArgs: cstring = nil) =
  ## Load an ELF binary from disk.
  ## Handles both ET_EXEC (direct load) and ET_DYN (PIE with relocation).
  ## PIE apps each get their own non-overlapping virtual region from
  ## the region allocator — so multiple apps can coexist simultaneously.
  if not fsMounted and not fsMount():
    kprint("No disk available\n")
    return
  kprint("Loading ELF: ")
  defaultSerial.putString(filename)
  kprint("...\n")
  let (res, nbytes) = fsReadInto(filename,
                                  cast[ptr byte](addr diskFileBuf[0]),
                                  diskFileBuf.len)
  if res != fOk:
    kprint("File read failed\n")
    return

  let dataBuf = cast[ptr byte](addr diskFileBuf[0])

  # Detect PIE (ET_DYN=3) vs non-PIE (ET_EXEC=2) from e_type at offset 16
  let elfType = cast[ptr uint16](cast[uint64](dataBuf) + 16)[]

  if elfType == 3:  # ET_DYN — PIE
    kprint("PIE ELF detected, loading with relocation...\n")

    # Ask the region allocator for a slot sized to this binary.
    # We don't know exact size until after parsing, so use RegionSize as
    # upper bound — the allocator enforces it fits.
    let slot = regionAlloc(RegionSize)
    if not regionValid(slot):
      kprint("No free region slots\n")
      return
    let base = regionBase(slot)
    klogInt(llInfo, "ELF PIE: region base=0x", int64(base))

    # ABI patch table — all 9 kernel ABI symbols injected at load time
    var patches: array[14, AbiPatch]
    patches[0] = AbiPatch(name: "nimixWrite",
                          fn: cast[uint64](abiModule.nimixWrite))
    patches[1] = AbiPatch(name: "nimixExit",
                          fn: cast[uint64](abiModule.nimixExit))
    patches[2] = AbiPatch(name: "nimixAllocRegion",
                          fn: cast[uint64](abiModule.nimixAllocRegion))
    patches[3] = AbiPatch(name: "nimixFreeRegion",
                          fn: cast[uint64](abiModule.nimixFreeRegion))
    patches[4] = AbiPatch(name: "nimixChanSend",
                          fn: cast[uint64](abiModule.nimixChanSend))
    patches[5] = AbiPatch(name: "nimixChanRecv",
                          fn: cast[uint64](abiModule.nimixChanRecv))
    patches[6] = AbiPatch(name: "nimixEventPublish",
                          fn: cast[uint64](abiModule.nimixEventPublish))
    patches[7] = AbiPatch(name: "nimixEventSubscribe",
                          fn: cast[uint64](abiModule.nimixEventSubscribe))
    patches[8] = AbiPatch(name: "nimixEventPoll",
                          fn: cast[uint64](abiModule.nimixEventPoll))
    patches[9]  = AbiPatch(name: "nimixGetArgs",
                           fn: cast[uint64](abiModule.nimixGetArgs))
    patches[10] = AbiPatch(name: "nimixProcList",
                           fn: cast[uint64](abiModule.nimixProcList))
    patches[11] = AbiPatch(name: "nimixSchedStats",
                           fn: cast[uint64](abiModule.nimixSchedStats))
    patches[12] = AbiPatch(name: "nimixProcKillPid",
                           fn: cast[uint64](abiModule.nimixProcKillPid))
    patches[13] = AbiPatch(name: "nimixFsReadDir",
                           fn: cast[uint64](abiModule.nimixFsReadDir))

    let loaded = elfLoadPie(dataBuf, nbytes, base,
                            cast[ptr UncheckedArray[AbiPatch]](addr patches[0]),
                            14)
    if loaded.err != elfOk:
      kprint("PIE ELF load failed\n")
      regionFree(slot)
      return
    if loaded.appMain == 0:
      kprint("appMain not found in PIE ELF\n")
      regionFree(slot)
      return

    kprint("Calling appMain...\n")
    let procSlot = procSpawn(filename, nil, tcApp, 128, int32(slot))
    setAppArgs(int(slot), appArgs)
    # Set current so abiGetArgs can find this app's regionSlot
    let prevCurrent = procTable.current
    if procSlot >= 0: procTable.current = int16(procSlot)
    let entry = cast[proc() {.nimcall.}](loaded.appMain)
    entry()
    procTable.current = prevCurrent
    if procSlot >= 0: discard procKill(procSlot)
    regionFree(slot)
  else:
    # ET_EXEC — direct load to fixed p_vaddr (legacy path, no relocation)
    let loaded = elfLoad(dataBuf, nbytes)
    if loaded.err != elfOk:
      kprint("ELF load failed\n")
      return
    kprint("Jumping to ELF entry...\n")
    let entry = cast[proc() {.nimcall.}](loaded.entry)
    entry()

# ── App exec helper ────────────────────────────────────────────────────────

proc execApp(name: cstring; args: cstring) =
  ## Load a PIE ELF app from disk with given args string.
  cmdExec(name, args)

# ── Main shell loop ────────────────────────────────────────────────────────

proc runShell*(physMgr: PhysicalMemManager) =
  ## Enter the interactive shell loop. Never returns.
  klog(llInfo, "Entering shell")
  kprint("\n")
  kprint("========================================\n")
  kprint("  Welcome to NimixOS\n")
  kprint("  Type 'help' for available commands.\n")
  kprint("========================================\n\n")

  var inputBuf: array[InputMax, char]
  var inputLen = 0

  kprint(ShellPrompt)

  while true:
    let c = defaultSerial.getChar()

    case c
    of '\r', '\n':
      defaultSerial.putChar('\n')
      let cmd = parseCommand(inputBuf, inputLen)
      let (first, last) = trimInput(inputBuf, inputLen)
      case cmd
      of scHelp:    cmdHelp()
      of scVersion: cmdVersion()
      of scMeminfo: cmdMeminfo(physMgr)
      of scClear:   cmdClear()
      of scModel:   cmdModel()
      of scLoadPing:
        kprint("[wasm] loading ping...\n")
        let r = wasmRun(cast[ptr byte](unsafeAddr pingWasm[0]), pingWasm.len)
        if r != wasmOk:
          kprint("[wasm] error running ping\n")
      of scLoadPingpong:
        kprint("[wasm] loading pingpong...\n")
        let caps = [CapIpc, CapEvents]
        let r = wasmRun(cast[ptr byte](unsafeAddr pingpongWasm[0]),
                        pingpongWasm.len, caps)
        if r != wasmOk:
          kprint("[wasm] error running pingpong\n")
      of scLs:      execApp("ls.elf", "/")
      of scRun:
        # extract filename after "run "
        var fname: array[128, char]
        var fi = 0
        var si = first + 4  # skip "run "
        while si <= last and fi < 127:
          fname[fi] = inputBuf[si]; inc fi; inc si
        fname[fi] = '\0'
        cmdRun(cast[cstring](addr fname[0]))
      of scExec:
        var fname: array[128, char]
        var fi = 0
        var si = first + 5  # skip "exec "
        while si <= last and fi < 127:
          fname[fi] = inputBuf[si]; inc fi; inc si
        fname[fi] = '\0'
        cmdExec(cast[cstring](addr fname[0]))
      of scPs:    execApp("ps.elf", "")
      of scKill:
        # Extract pid string after "kill "
        var pidBuf: array[32, char]
        var pi = 0
        var si = first + 5  # skip "kill "
        while si <= last and inputBuf[si] == ' ': inc si
        while si <= last and pi < 31:
          pidBuf[pi] = inputBuf[si]; inc pi; inc si
        pidBuf[pi] = '\0'
        execApp("kill.elf", cast[cstring](addr pidBuf[0]))
      of scStats: execApp("stats.elf", "")
      of scEmpty:   discard
      of scUnknown: cmdUnknown(inputBuf, first, last)
      # Reset buffer
      for i in 0..<inputLen: inputBuf[i] = '\0'
      inputLen = 0
      kprint(ShellPrompt)

    of '\b', char(127):
      if inputLen > 0:
        dec inputLen
        inputBuf[inputLen] = '\0'
        defaultSerial.putChar('\b')
        defaultSerial.putChar(' ')
        defaultSerial.putChar('\b')

    else:
      if inputLen < InputMax - 1:
        inputBuf[inputLen] = c
        inc inputLen
        defaultSerial.putChar(c)
