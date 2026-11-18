# SPDX-License-Identifier: GPL-2.0
## Structured Kernel Logging - LAYER 0
##
## Compile-time log level filtering via -d:logLevel=N
## 0=DEBUG 1=INFO(default) 2=WARN 3=ERROR 4=PANIC
##
## Usage:
##   klog(llInfo, "kernel started")
##   klogHex(llDebug, "addr=", 0xB8000'u64)
##   kassert(ptr != nil, "null pointer")
##   kpanic("unrecoverable error")

import ./log_types
export log_types  # re-export so importers only need `import core/log`

import ./serial
import ./klog_ring

const
  LevelPrefix: array[LogLevel, cstring] = [
    "[DEBUG] ",
    "[INFO]  ",
    "[WARN]  ",
    "[ERROR] ",
    "[PANIC] "
  ]

proc klog*(level: LogLevel, msg: cstring) {.inline.} =
  ## Log message at given level. Messages below KernelLogLevel are no-ops.
  if ord(level) >= KernelLogLevel:
    defaultSerial.putString(LevelPrefix[level])
    defaultSerial.putString(msg)
    defaultSerial.putChar('\n')
    klogRingPut(LevelPrefix[level]); klogRingPut(msg); klogRingPut('\n')

proc klogHex*(level: LogLevel, label: cstring, val: uint64) {.inline.} =
  ## Log label + hex value.
  if ord(level) >= KernelLogLevel:
    defaultSerial.putString(LevelPrefix[level])
    defaultSerial.putString(label)
    defaultSerial.putString("0x")
    defaultSerial.putHex(val)
    defaultSerial.putChar('\n')
    klogRingPut(LevelPrefix[level]); klogRingPut(label); klogRingPut("0x")
    klogRingPutHex(val); klogRingPut('\n')

proc klogInt*(level: LogLevel, label: cstring, val: int64) {.inline.} =
  ## Log label + decimal integer.
  if ord(level) >= KernelLogLevel:
    defaultSerial.putString(LevelPrefix[level])
    defaultSerial.putString(label)
    defaultSerial.putInt(val)
    defaultSerial.putChar('\n')
    klogRingPut(LevelPrefix[level]); klogRingPut(label); klogRingPutInt(val)
    klogRingPut('\n')

proc kpanic*(msg: cstring) {.noreturn, inline.} =
  ## Print panic message and halt the CPU forever. No recovery.
  defaultSerial.putString("\n[PANIC] ")
  defaultSerial.putString(msg)
  defaultSerial.putString("\n[PANIC] System halted.\n")
  while true:
    when defined(amd64) or defined(x86_64):
      {.emit: "asm volatile(\"cli; hlt\");".}
    else:
      discard

template kassert*(cond: bool, msg: cstring) =
  ## Kernel assert: calls kpanic if condition is false.
  if not cond:
    kpanic(msg)
