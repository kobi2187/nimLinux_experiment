# SPDX-License-Identifier: GPL-2.0
## Timer and Clock System
##
## Manages system timer, time quantum for preemption,
## and high-resolution timing for the kernel

import ../core/types

type
  # ═══════════════════════════════════════════════════════════════════════════
  # Timer Types
  # ═══════════════════════════════════════════════════════════════════════════

  TimerMode* = enum
    ## Timer interrupt modes
    tmOneShot               ## Single interrupt
    tmPeriodic              ## Recurring interrupts

  TimerSource* = enum
    ## Timer hardware sources
    tsPit = 0               ## Programmable Interval Timer (8254)
    tsApic = 1              ## Local APIC timer
    tsHpet = 2              ## High Precision Event Timer
    tsTsc = 3               ## Time Stamp Counter (read-only)

  TimerInfo* = object
    ## System timer information
    source*: TimerSource
    frequency*: uint64      ## Hz
    resolution*: uint64     ## Nanoseconds per tick
    maxTicks*: uint64

  ClockTime* = object
    ## Absolute time representation
    seconds*: uint64
    nanoseconds*: uint32

  TimerCallback* = proc(timerId: uint32, userData: pointer) {.cdecl.}

# ═══════════════════════════════════════════════════════════════════════════
# Global Timer State
# ═══════════════════════════════════════════════════════════════════════════

const
  HZ* = 1000'u64                  ## System timer frequency (1000 Hz = 1ms ticks)
  TimeSlice* = 10'u64             ## Default time quantum (10ms)
  TicksPerSecond* = HZ
  NanosecondsPerSecond* = 1_000_000_000'u64

var
  gSystemTime*: ClockTime
  gTimerTicks*: uint64
  gPreemptionEnabled*: bool = true

# ═══════════════════════════════════════════════════════════════════════════
# PIT (Programmable Interval Timer) - 8254 Chip
# ═══════════════════════════════════════════════════════════════════════════

const
  PitChannelZeroData* = 0x40'u16
  PitChannelOneData* = 0x41'u16
  PitChannelTwoData* = 0x42'u16
  PitCommand* = 0x43'u16
  PitBaseFreq* = 1_193_182'u32   ## PIT oscillator frequency

  # PIT command byte bits
  PitCounterSelect0* = 0x00'u8
  PitCounterSelect1* = 0x40'u8
  PitCounterSelect2* = 0x80'u8
  PitAccessLatched* = 0x00'u8
  PitAccessLo* = 0x10'u8
  PitAccessHi* = 0x20'u8
  PitAccessLoHi* = 0x30'u8
  PitModeInterrupt* = 0x00'u8
  PitModeOneShot* = 0x02'u8
  PitModeRateGen* = 0x04'u8
  PitModeSqWave* = 0x06'u8
  PitModeSoftTrig* = 0x08'u8
  PitModeHwTrig* = 0x0A'u8
  PitBcd* = 0x01'u8

proc pitSetFrequency*(frequency: uint32) =
  ## Set PIT frequency by programming divisor
  ## frequency must be >= 18 Hz (divisor must fit in 16 bits)
  let divisor = PitBaseFreq div frequency
  # outb(PitCommand, PitCounterSelect0 or PitAccessLoHi or PitModeRateGen)
  # outb(PitChannelZeroData, uint8(divisor and 0xFF))
  # outb(PitChannelZeroData, uint8((divisor shr 8) and 0xFF))

proc pitEnable*() =
  ## Enable PIT timer
  pitSetFrequency(uint32(HZ))

proc pitDisable*() =
  ## Disable PIT timer
  discard

# ═══════════════════════════════════════════════════════════════════════════
# APIC Timer (Local APIC)
# ═══════════════════════════════════════════════════════════════════════════

const
  ApicTimerDivide* = 0x3E0'u32
  ApicTimerInitial* = 0x380'u32
  ApicTimerCurrent* = 0x390'u32
  ApicTimerVectorTable* = 0x3E0'u32
  ApicTimerDivideBy1* = 0x0B'u32
  ApicTimerModeOneShot* = 0'u32
  ApicTimerModePeriodic* = 0x20000'u32

proc apicTimerSetFrequency*(frequency: uint64) =
  ## Set APIC timer frequency
  discard

proc apicTimerEnable*() =
  ## Enable APIC timer with periodic mode
  discard

proc apicTimerDisable*() =
  ## Disable APIC timer
  discard

# ═══════════════════════════════════════════════════════════════════════════
# System Clock Management
# ═══════════════════════════════════════════════════════════════════════════

proc getSystemTime*(): ClockTime =
  ## Get current absolute time
  result.seconds = gSystemTime.seconds
  result.nanoseconds = gSystemTime.nanoseconds

proc setSystemTime*(time: ClockTime) =
  ## Set absolute system time
  gSystemTime = time

proc getTimerTicks*(): uint64 =
  ## Get total number of timer ticks since boot
  return gTimerTicks

proc getMilliseconds*(): uint64 =
  ## Get time in milliseconds since boot
  return gTimerTicks div (HZ div 1000)

proc getMicroseconds*(): uint64 =
  ## Get time in microseconds since boot
  return gTimerTicks * (1_000_000 div HZ)

# ═══════════════════════════════════════════════════════════════════════════
# Timer Callbacks
# ═══════════════════════════════════════════════════════════════════════════

var gTimerCallbacks*: array[32, TimerCallback]
var gTimerUserData*: array[32, pointer]

proc registerTimerCallback*(timerId: uint32, callback: TimerCallback, userData: pointer = nil) =
  ## Register a callback for periodic timer interrupts
  if timerId < 32:
    gTimerCallbacks[timerId] = callback
    gTimerUserData[timerId] = userData

proc invokeTimerCallbacks*() =
  ## Call all registered timer callbacks (called from timer ISR)
  for i in 0..<32:
    if gTimerCallbacks[i] != nil:
      gTimerCallbacks[i](uint32(i), gTimerUserData[i])

# ═══════════════════════════════════════════════════════════════════════════
# Preemption Control
# ═══════════════════════════════════════════════════════════════════════════

proc enablePreemption*() =
  ## Enable timer-based preemption
  gPreemptionEnabled = true

proc disablePreemption*() =
  ## Disable timer-based preemption
  gPreemptionEnabled = false

proc isPreemptionEnabled*(): bool =
  ## Check if preemption is enabled
  return gPreemptionEnabled

# ═══════════════════════════════════════════════════════════════════════════
# Timer Interrupt Handler
# ═══════════════════════════════════════════════════════════════════════════

proc shouldPreempt*(): bool =
  ## Check if preemption should occur
  # Strategy: Return true if preemption enabled and time quantum expired
  return gPreemptionEnabled and (gTimerTicks mod TimeSlice) == 0

var gSleepingProcesses*: array[256, tuple[pid: uint32, wakeupTick: uint64]]
var gSleepCount: uint32 = 0

proc addSleepingProcess*(pid: uint32, durationMs: uint64) =
  ## Add process to sleep queue
  # Strategy: Calculate wake-up time and store in list
  if gSleepCount < 256:
    let wakeupTick = gTimerTicks + (durationMs * HZ div 1000)
    gSleepingProcesses[gSleepCount].pid = pid
    gSleepingProcesses[gSleepCount].wakeupTick = wakeupTick
    inc gSleepCount

proc trySleepProcess*(pid: uint32, durationMs: uint64): Result[void, KernelError] =
  ## Add process to sleep queue with Result-based error handling
  # Strategy: Return error if sleep queue is full
  if gSleepCount >= 256:
    return err[void, KernelError](keOutOfMemory)
  addSleepingProcess(pid, durationMs)
  return ok[void, KernelError]()

proc checkSleepingProcesses*(): seq[uint32] =
  ## Check which sleeping processes should wake up
  # Strategy: Compare wake-up times, return PIDs to wake
  var toWake: seq[uint32] = @[]
  var writeIdx = 0

  for i in 0..<gSleepCount:
    if gSleepingProcesses[i].wakeupTick <= gTimerTicks:
      toWake.add(gSleepingProcesses[i].pid)
    else:
      # Keep this entry (not expired yet)
      gSleepingProcesses[writeIdx] = gSleepingProcesses[i]
      inc writeIdx

  gSleepCount = writeIdx
  return toWake

proc handleTimerInterrupt*() {.cdecl.} =
  ## Called on each timer tick (IRQ0)
  # Strategy: Update time, invoke callbacks, check for preemption, wake sleeping procs
  inc gTimerTicks

  # Update absolute time
  inc gSystemTime.nanoseconds, NanosecondsPerSecond div HZ
  if gSystemTime.nanoseconds >= NanosecondsPerSecond:
    inc gSystemTime.seconds
    gSystemTime.nanoseconds -= NanosecondsPerSecond'u32

  # Invoke registered callbacks
  invokeTimerCallbacks()

  # Check if sleeping processes should wake
  let readyPids = checkSleepingProcesses()
  # TODO: Move readyPids to scheduler ready queue (integrate with process scheduler)

  # Request preemption if enabled and time quantum expired
  if shouldPreempt():
    # TODO: Trigger context switch via scheduler (save current context, select next process)
    discard

# ═══════════════════════════════════════════════════════════════════════════
# Timer Initialization
# ═══════════════════════════════════════════════════════════════════════════

proc initTimer*(source: TimerSource = tsPit) =
  ## Initialize system timer
  gSystemTime = ClockTime(seconds: 0, nanoseconds: 0)
  gTimerTicks = 0
  gPreemptionEnabled = true

  case source
  of tsPit:
    pitEnable()
  of tsApic:
    apicTimerEnable()
  of tsHpet:
    # HPET initialization would go here
    discard
  of tsTsc:
    # TSC is read-only, just for monotonic clock
    discard

proc shutdownTimer*() =
  ## Shut down system timer
  pitDisable()
  apicTimerDisable()

proc getTimerInfo*(source: TimerSource): TimerInfo =
  ## Get information about a timer source
  case source
  of tsPit:
    result.source = tsPit
    result.frequency = HZ
    result.resolution = NanosecondsPerSecond div HZ
    result.maxTicks = 0x10000'u64
  of tsApic:
    result.source = tsApic
    result.frequency = HZ
    result.resolution = NanosecondsPerSecond div HZ
    result.maxTicks = high(uint32)
  of tsHpet:
    result.source = tsHpet
    result.frequency = 14_318_180'u64
    result.resolution = 69              ## 69 nanoseconds
    result.maxTicks = high(uint64)
  of tsTsc:
    result.source = tsTsc
    result.frequency = 2_400_000_000'u64
    result.resolution = 1
    result.maxTicks = high(uint64)

proc printTimerStats*(): string =
  ## Return formatted timer statistics
  let ms = getMilliseconds()
  let us = getMicroseconds()
  "Timer: " & $gTimerTicks & " ticks, " & $ms & "ms, " & $us & "us"
