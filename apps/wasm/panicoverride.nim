# SPDX-License-Identifier: GPL-2.0
## Panic handling for Nim WASM apps: report on serial, then leave the sandbox.

proc wasmSerialWrite(p: pointer; n: int32) {.importc: "serial_write",
  codegenDecl: "__attribute__((import_module(\"env\"), import_name(\"serial_write\"))) $1 $2$3".}
proc wasmExit(code: int32) {.importc: "sip_exit",
  codegenDecl: "__attribute__((import_module(\"env\"), import_name(\"sip_exit\"))) $1 $2$3".}

{.push stack_trace: off, profiler: off.}

proc rawoutput(s: string) =
  if s.len > 0: wasmSerialWrite(unsafeAddr s[0], int32(s.len))

proc panic(s: string) {.noreturn.} =
  rawoutput("app panic: ")
  rawoutput(s)
  rawoutput("\n")
  wasmExit(1)
  {.emit: "__builtin_trap();".}
  while true: discard

{.pop.}
