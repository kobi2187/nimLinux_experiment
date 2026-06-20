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
import ../apps/ping/ping_embedded

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
    scLoad    ## load <app> — run a built-in WASM app

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
  if bufEq(buf, first, last, "load ping"): return scLoad
  scUnknown

# ── Command implementations ────────────────────────────────────────────────

proc cmdHelp() =
  kprint("Commands:\n")
  kprint("  help       - show this message\n")
  kprint("  version    - kernel version and model\n")
  kprint("  meminfo    - physical memory usage\n")
  kprint("  clear      - scroll past old output\n")
  kprint("  model      - current kernel architecture model\n")
  kprint("  load ping  - run the embedded ping WASM app\n")

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
      of scLoad:
        kprint("[wasm] loading ping...\n")
        let r = wasmRun(cast[ptr byte](unsafeAddr pingWasm[0]), pingWasm.len)
        if r != wasmOk:
          kprint("[wasm] error: ")
          kprint($r)
          kprint("\n")
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
