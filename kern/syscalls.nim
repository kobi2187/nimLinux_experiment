# SPDX-License-Identifier: GPL-2.0
## System Call Interface
##
## Defines the syscall entry points and dispatch mechanism
## for user-space programs to request kernel services

import ../core/types

type
  # ═══════════════════════════════════════════════════════════════════════════
  # Syscall Numbers
  # ═══════════════════════════════════════════════════════════════════════════

  SyscallNumber* = enum
    ## Syscall numbers (x86-64 calling convention)
    scExit = 0
    scRead = 1
    scWrite = 2
    scOpen = 3
    scClose = 4
    scStat = 5
    scFstat = 6
    scLstat = 7
    scPoll = 8
    scLseek = 9
    scMmap = 10
    scMprotect = 11
    scMunmap = 12
    scBrk = 13
    scRtSigaction = 14
    scRtSigprocmask = 15
    scRtSigpending = 16
    scRtSigtimedwait = 17
    scRtSigqueueinfo = 18
    scRtSigreturn = 19
    scIoctl = 20
    scPread64 = 21
    scPwrite64 = 22
    scReadv = 23
    scWritev = 24
    scAccess = 25
    scPipe = 26
    scSelect = 27
    scSchedYield = 28
    scMremap = 29
    scMsync = 30
    scMincore = 31
    scMadvise = 32
    scShmget = 33
    scShmat = 34
    scShmctl = 35
    scDup = 36
    scDup2 = 37
    scPause = 38
    scNanosleep = 39
    scGetitimer = 40
    scAlarm = 41
    scSetitimer = 42
    scGetpid = 43
    scSendfile = 44
    scSocket = 45
    scConnect = 46
    scAccept = 47

  SyscallError* = enum
    ## Syscall error codes (negative errno)
    seSuccess = 0
    seEperm = -1           ## Operation not permitted
    seEnoent = -2          ## No such file or directory
    seEsrch = -3           ## No such process
    seEintr = -4           ## Interrupted system call
    seEio = -5             ## I/O error
    seEnxio = -6           ## No such device or address
    se2big = -7            ## Argument list too long
    seEnoexec = -8         ## Exec format error
    seEbadf = -9           ## Bad file descriptor
    seEchild = -10         ## No child processes
    seEagain = -11         ## Resource temporarily unavailable
    seEnomem = -12         ## Out of memory
    seEacces = -13         ## Permission denied
    seEfault = -14         ## Bad address
    seEnotblk = -15        ## Block device required
    seEbusy = -16          ## Device or resource busy
    seEexist = -17         ## File exists
    seExdev = -18          ## Invalid cross-device link
    seEnodev = -19         ## No such device
    seEnotdir = -20        ## Not a directory

  SyscallContext* = object
    ## User-space context when syscall is issued
    rax*: uint64           ## Syscall number / return value
    rdi*: uint64           ## Arg 1
    rsi*: uint64           ## Arg 2
    rdx*: uint64           ## Arg 3
    rcx*: uint64           ## Arg 4
    r8*: uint64            ## Arg 5
    r9*: uint64            ## Arg 6
    rsp*: uint64           ## Stack pointer
    rbp*: uint64           ## Base pointer

  SyscallHandler* = proc(num: SyscallNumber, ctx: ptr SyscallContext): int64 {.cdecl.}

# ═══════════════════════════════════════════════════════════════════════════
# Syscall Dispatch Table
# ═══════════════════════════════════════════════════════════════════════════

var gSyscallHandlers*: array[512, SyscallHandler]

proc registerSyscallHandler*(num: SyscallNumber, handler: SyscallHandler) =
  ## Register a handler for a syscall number
  gSyscallHandlers[ord(num)] = handler

proc getSyscallHandler*(num: SyscallNumber): SyscallHandler =
  ## Get handler for syscall number (returns null handler if not implemented)
  let idx = ord(num)
  if idx < 512:
    return gSyscallHandlers[idx]
  return nil

# ═══════════════════════════════════════════════════════════════════════════
# Generic Syscall Entry Point
# ═══════════════════════════════════════════════════════════════════════════

proc handleSyscall*(num: SyscallNumber, ctx: ptr SyscallContext): int64 =
  ## Dispatch syscall to appropriate handler
  ## This is called from assembly entry point
  let handler = getSyscallHandler(num)
  if handler != nil:
    return handler(num, ctx)
  return ord(seEbadf)  ## Bad syscall number

# ═══════════════════════════════════════════════════════════════════════════
# Common Syscall Implementations
# ═══════════════════════════════════════════════════════════════════════════

proc scExit*(ctx: ptr SyscallContext): int64 =
  ## Exit current process with code
  let exitCode = ctx.rdi
  # Would terminate process and switch to next task
  0

proc scWrite*(ctx: ptr SyscallContext): int64 =
  ## Write to file descriptor
  let fd = ctx.rdi
  let buf = cast[ptr uint8](ctx.rsi)
  let count = ctx.rdx
  # Would write bytes to file descriptor
  int64(count)

proc scRead*(ctx: ptr SyscallContext): int64 =
  ## Read from file descriptor
  let fd = ctx.rdi
  let buf = cast[ptr uint8](ctx.rsi)
  let count = ctx.rdx
  # Would read bytes from file descriptor
  0

proc scOpen*(ctx: ptr SyscallContext): int64 =
  ## Open file
  let path = cast[cstring](ctx.rdi)
  let flags = ctx.rsi
  let mode = ctx.rdx
  # Would open file and return fd
  -1

proc scClose*(ctx: ptr SyscallContext): int64 =
  ## Close file descriptor
  let fd = ctx.rdi
  # Would close fd
  0

proc scBrk*(ctx: ptr SyscallContext): int64 =
  ## Set/get program break (heap limit)
  let newBreak = ctx.rdi
  # Would adjust heap
  newBreak

proc scMmap*(ctx: ptr SyscallContext): int64 =
  ## Map memory
  let addr = ctx.rdi
  let length = ctx.rsi
  let prot = ctx.rdx
  let flags = ctx.rcx
  let fd = ctx.r8
  let offset = ctx.r9
  # Would allocate virtual memory
  -1

proc scMunmap*(ctx: ptr SyscallContext): int64 =
  ## Unmap memory
  let addr = ctx.rdi
  let length = ctx.rsi
  # Would deallocate virtual memory
  0

proc scGetpid*(ctx: ptr SyscallContext): int64 =
  ## Get current process ID
  # Would return current pid
  1

# ═══════════════════════════════════════════════════════════════════════════
# Syscall Validation and Context
# ═══════════════════════════════════════════════════════════════════════════

proc validateSyscallContext*(ctx: ptr SyscallContext): bool =
  ## Validate user-space context before processing
  # Strategy: Check for null pointer and basic sanity
  if ctx == nil:
    return false
  # In real implementation: would validate user-space addresses, permissions
  return true

var gSyscallCount*: uint64 = 0
var gSyscallErrors*: array[64, uint64]
var gSyscallStats*: array[512, tuple[count: uint64, totalTime: uint64]]

proc recordSyscall*(num: SyscallNumber) =
  ## Record syscall statistics
  # Strategy: Increment count and track timing
  inc gSyscallCount
  if ord(num) < 512:
    inc gSyscallStats[ord(num)].count

proc getSyscallStats*(num: SyscallNumber): tuple[count: uint64, totalTime: uint64] =
  ## Get statistics for specific syscall
  # Strategy: Return call count and total time
  if ord(num) < 512:
    return gSyscallStats[ord(num)]
  return (0, 0)

proc getSyscallName*(num: SyscallNumber): string =
  ## Get human-readable syscall name
  # Strategy: Map enum to string
  case num
  of scExit: "exit"
  of scRead: "read"
  of scWrite: "write"
  of scOpen: "open"
  of scClose: "close"
  of scStat: "stat"
  of scBrk: "brk"
  of scMmap: "mmap"
  of scMunmap: "munmap"
  of scGetpid: "getpid"
  else: "unknown"

# ═══════════════════════════════════════════════════════════════════════════
# Syscall Initialization
# ═══════════════════════════════════════════════════════════════════════════

proc initSyscalls*() =
  ## Initialize syscall handlers
  # Strategy: Register handlers for core syscalls
  registerSyscallHandler(scExit, proc(num: SyscallNumber, ctx: ptr SyscallContext): int64 = scExit(ctx))
  registerSyscallHandler(scRead, proc(num: SyscallNumber, ctx: ptr SyscallContext): int64 = scRead(ctx))
  registerSyscallHandler(scWrite, proc(num: SyscallNumber, ctx: ptr SyscallContext): int64 = scWrite(ctx))
  registerSyscallHandler(scOpen, proc(num: SyscallNumber, ctx: ptr SyscallContext): int64 = scOpen(ctx))
  registerSyscallHandler(scClose, proc(num: SyscallNumber, ctx: ptr SyscallContext): int64 = scClose(ctx))
  registerSyscallHandler(scBrk, proc(num: SyscallNumber, ctx: ptr SyscallContext): int64 = scBrk(ctx))
  registerSyscallHandler(scMmap, proc(num: SyscallNumber, ctx: ptr SyscallContext): int64 = scMmap(ctx))
  registerSyscallHandler(scMunmap, proc(num: SyscallNumber, ctx: ptr SyscallContext): int64 = scMunmap(ctx))
  registerSyscallHandler(scGetpid, proc(num: SyscallNumber, ctx: ptr SyscallContext): int64 = scGetpid(ctx))

proc syscallErrorToString*(error: SyscallError): string =
  ## Convert syscall error to message
  # Strategy: Map error code to descriptive string
  case error
  of seSuccess: "Success"
  of seEperm: "Operation not permitted"
  of seEnoent: "No such file or directory"
  of seEsrch: "No such process"
  of seEintr: "Interrupted system call"
  of seEio: "I/O error"
  of seEnxio: "No such device or address"
  of se2big: "Argument list too long"
  of seEbadf: "Bad file descriptor"
  of seEchild: "No child processes"
  of seEagain: "Resource temporarily unavailable"
  of seEnomem: "Out of memory"
  of seEacces: "Permission denied"
  else: "Unknown error"

proc printSyscallStats*(): string =
  ## Print syscall statistics
  # Strategy: Format total count and common syscalls
  var result = "Syscall Statistics:\n"
  result = result & "Total: " & $gSyscallCount & " syscalls\n"
  result = result & "Top syscalls:\n"

  var topCount = 0
  for i in 0..<512:
    if gSyscallStats[i].count > 0:
      if topCount < 10:
        let scNum = SyscallNumber(i)
        result = result & "  " & getSyscallName(scNum) & ": " &
                 $gSyscallStats[i].count & " calls\n"
      inc topCount

  return result
