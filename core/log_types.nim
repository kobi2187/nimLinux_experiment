# SPDX-License-Identifier: GPL-2.0
## Log Level Types - no dependencies
## Split out so tests can import just the types without serial hardware dep.

type
  LogLevel* = enum
    llDebug = 0
    llInfo  = 1
    llWarn  = 2
    llError = 3
    llPanic = 4

const
  KernelLogLevel* {.intdefine: "logLevel".} = 1  ## Default: INFO, override with -d:logLevel=0 for DEBUG
