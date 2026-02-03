# SPDX-License-Identifier: GPL-2.0
## Process Management
##
## Manages user-space processes, their memory spaces,
## file descriptors, and lifecycle

import ../core/types

type
  # ═══════════════════════════════════════════════════════════════════════════
  # Process Types
  # ═══════════════════════════════════════════════════════════════════════════

  ProcessState* = enum
    psCreating = 0
    psReady = 1
    psRunning = 2
    psWaiting = 3
    psStopped = 4
    psZombie = 5
    psTerminated = 6

  ProcessPriority* = enum
    ppIdle = 0
    ppLow = 1
    ppNormal = 2
    ppHigh = 3
    ppRealtime = 4

  ProcessFlags* = distinct uint16

  FileDescriptor* = object
    ## File descriptor entry
    inUse*: bool
    flags*: uint16
    position*: uint64
    # Would have inode/file pointer here

  VirtualAddressSpace* = object
    ## User-space virtual address mapping
    # Would contain page tables and memory regions
    regionCount*: uint8

  ProcessContext* = object
    ## Saved register context for process
    rax*, rbx*, rcx*, rdx*: uint64
    rsi*, rdi*, rbp*, rsp*: uint64
    r8*, r9*, r10*, r11*: uint64
    r12*, r13*, r14*, r15*: uint64
    rip*, rflags*: uint64

  Process* = object
    ## Process control block
    pid*: uint32
    ppid*: uint32                        ## Parent PID
    uid*: uint32                         ## User ID
    gid*: uint32                         ## Group ID
    state*: ProcessState
    priority*: ProcessPriority
    flags*: ProcessFlags

    # Scheduling
    cpuTime*: uint64                     ## Total CPU time used (ticks)
    createdAt*: uint64                   ## Creation time (ticks)
    lastScheduled*: uint64               ## Last run time
    quantumRemaining*: uint64            ## Remaining time quantum

    # Memory
    vaddr*: VirtualAddressSpace
    heapStart*: VirtAddr
    heapEnd*: VirtAddr
    stackStart*: VirtAddr
    stackEnd*: VirtAddr

    # File descriptors
    fileDescriptors*: array[256, FileDescriptor]
    cwd*: uint32                         ## Current working directory inode

    # Saved state
    context*: ProcessContext
    signalHandlers*: array[32, pointer]  ## Signal handlers

# ═══════════════════════════════════════════════════════════════════════════
# Process Constants
# ═══════════════════════════════════════════════════════════════════════════

const
  MaxProcesses* = 65536
  MaxFileDescriptorsPerProcess* = 256
  DefaultStackSize* = 8192               ## 8 KB per process
  DefaultHeapSize* = 65536               ## 64 KB initial heap

# ═══════════════════════════════════════════════════════════════════════════
# Global Process Table
# ═══════════════════════════════════════════════════════════════════════════

var
  gProcessTable*: array[MaxProcesses, Process]
  gNextPid*: uint32 = 1
  gProcessCount*: uint32 = 0

# ═══════════════════════════════════════════════════════════════════════════
# Process Creation
# ═══════════════════════════════════════════════════════════════════════════

proc createProcess*(parentPid: uint32, priority: ProcessPriority = ppNormal): uint32 =
  ## Create a new process
  ## Returns PID of created process or 0 on failure
  if gProcessCount >= MaxProcesses:
    return 0

  let pid = gNextPid
  inc gNextPid
  if gNextPid >= MaxProcesses:
    gNextPid = 1

  var process: Process
  process.pid = pid
  process.ppid = parentPid
  process.state = psCreating
  process.priority = priority
  process.cpuTime = 0
  process.createdAt = 0  # Would be current tick
  process.quantumRemaining = 10  # Default time quantum
  process.uid = 0  # Root for now
  process.gid = 0

  if pid < MaxProcesses:
    gProcessTable[pid] = process
    inc gProcessCount

  return pid

proc getProcess*(pid: uint32): ptr Process =
  ## Get process by PID
  if pid < MaxProcesses:
    return addr gProcessTable[pid]
  return nil

proc terminateProcess*(pid: uint32): bool =
  ## Terminate a process
  let proc = getProcess(pid)
  if proc != nil and proc.state != psTerminated:
    proc.state = psTerminated
    return true
  return false

proc setProcessState*(pid: uint32, state: ProcessState): bool =
  ## Change process state
  let proc = getProcess(pid)
  if proc != nil:
    proc.state = state
    return true
  return false

proc getProcessState*(pid: uint32): ProcessState =
  ## Get current process state
  let proc = getProcess(pid)
  if proc != nil:
    return proc.state
  return psTerminated

# ═══════════════════════════════════════════════════════════════════════════
# File Descriptor Management
# ═══════════════════════════════════════════════════════════════════════════

proc allocateFileDescriptor*(pid: uint32): int32 =
  ## Allocate file descriptor for process
  ## Returns FD number or -1 if none available
  let proc = getProcess(pid)
  if proc == nil:
    return -1
  for i in 0..<MaxFileDescriptorsPerProcess:
    if not proc.fileDescriptors[i].inUse:
      proc.fileDescriptors[i].inUse = true
      return int32(i)
  return -1

proc closeFileDescriptor*(pid: uint32, fd: int32): bool =
  ## Close a file descriptor
  let proc = getProcess(pid)
  if proc != nil and fd >= 0 and fd < MaxFileDescriptorsPerProcess:
    proc.fileDescriptors[fd].inUse = false
    return true
  return false

proc getFileDescriptor*(pid: uint32, fd: int32): ptr FileDescriptor =
  ## Get file descriptor
  let proc = getProcess(pid)
  if proc != nil and fd >= 0 and fd < MaxFileDescriptorsPerProcess:
    if proc.fileDescriptors[fd].inUse:
      return addr proc.fileDescriptors[fd]
  return nil

# ═══════════════════════════════════════════════════════════════════════════
# Process Priority and Scheduling
# ═══════════════════════════════════════════════════════════════════════════

proc setPriority*(pid: uint32, priority: ProcessPriority): bool =
  ## Change process priority
  let proc = getProcess(pid)
  if proc != nil:
    proc.priority = priority
    return true
  return false

proc getPriority*(pid: uint32): ProcessPriority =
  ## Get process priority
  let proc = getProcess(pid)
  if proc != nil:
    return proc.priority
  return ppNormal

proc addCpuTime*(pid: uint32, ticks: uint64) =
  ## Add CPU time to process
  let proc = getProcess(pid)
  if proc != nil:
    proc.cpuTime += ticks

proc getCpuTime*(pid: uint32): uint64 =
  ## Get total CPU time used by process
  let proc = getProcess(pid)
  if proc != nil:
    return proc.cpuTime
  return 0

# ═══════════════════════════════════════════════════════════════════════════
# Process Statistics
# ═══════════════════════════════════════════════════════════════════════════

proc getProcessCount*(): uint32 =
  ## Get total number of live processes
  return gProcessCount

proc listRunningProcesses*(): seq[uint32] =
  ## Get list of all PIDs
  result = @[]
  for i in 0..<MaxProcesses:
    if gProcessTable[i].state != psTerminated and gProcessTable[i].pid > 0:
      result.add(gProcessTable[i].pid)

proc getProcessInfo*(pid: uint32): string =
  ## Get formatted process information
  let proc = getProcess(pid)
  if proc == nil:
    return "Process not found"
  "PID: " & $proc.pid & " State: " & $proc.state & " Priority: " & $proc.priority

proc processStats*(): string =
  ## Return formatted process statistics
  "Processes: " & $gProcessCount & "/" & $MaxProcesses &
  " | Next PID: " & $gNextPid

# ═══════════════════════════════════════════════════════════════════════════
# Process Context Switching
# ═══════════════════════════════════════════════════════════════════════════

proc saveProcessContext*(pid: uint32, context: ProcessContext): bool =
  ## Save register context for process
  let proc = getProcess(pid)
  if proc != nil:
    proc.context = context
    return true
  return false

proc restoreProcessContext*(pid: uint32): ProcessContext =
  ## Restore register context for process
  let proc = getProcess(pid)
  if proc != nil:
    return proc.context
  return ProcessContext()

proc copyProcessContext*(fromPid: uint32, toPid: uint32): bool =
  ## Copy context from one process to another (for fork)
  let fromProc = getProcess(fromPid)
  let toProc = getProcess(toPid)
  if fromProc != nil and toProc != nil:
    toProc.context = fromProc.context
    return true
  return false

# ═══════════════════════════════════════════════════════════════════════════
# Process Memory Management
# ═══════════════════════════════════════════════════════════════════════════

proc setProcessMemoryLayout*(pid: uint32, heapStart: VirtAddr, stackStart: VirtAddr) =
  ## Set process memory region boundaries
  let proc = getProcess(pid)
  if proc != nil:
    proc.heapStart = heapStart
    proc.stackStart = stackStart
    proc.stackEnd = stackStart + DefaultStackSize

proc getProcessMemoryUsage*(pid: uint32): uint64 =
  ## Get total memory used by process
  # Would calculate from memory regions
  0

# ═══════════════════════════════════════════════════════════════════════════
# Init and Cleanup
# ═══════════════════════════════════════════════════════════════════════════

proc initProcessManagement*() =
  ## Initialize process management system
  gProcessCount = 0
  gNextPid = 1

proc cleanupTerminatedProcesses*() =
  ## Reap terminated (zombie) processes and free resources
  for i in 0..<MaxProcesses:
    if gProcessTable[i].state == psTerminated:
      # Would free memory and clean up
      if gProcessCount > 0:
        dec gProcessCount
