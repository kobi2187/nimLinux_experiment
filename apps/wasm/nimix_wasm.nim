# SPDX-License-Identifier: GPL-2.0
## NimixOS WASM app SDK — regular apps are WASM (system tools/servers are ELF).
##
## An app only reaches what the shell granted it: serial_write/sip_exit/events
## always, chan_send only with CapIpc. Entry: `nimixWasmMain: <body>`.

{.compile: "nimix_wasm_rt.c".}

template hostImport(name: string): untyped =
  ## Declare `env.<name>` as a WASM import.
  "__attribute__((import_module(\"env\"), import_name(\"" & name & "\"))) $1 $2$3"

proc serial_write(p: pointer; n: int32) {.importc, codegenDecl: hostImport("serial_write").}
proc sip_exit(code: int32) {.importc, codegenDecl: hostImport("sip_exit").}
proc chan_send(name: cstring; data: pointer; n: int32) {.importc, codegenDecl: hostImport("chan_send").}
proc event_subscribe(topic: cstring): int32 {.importc, codegenDecl: hostImport("event_subscribe").}
proc event_wait(token: int32; buf: pointer; maxLen: int32): int32 {.importc, codegenDecl: hostImport("event_wait").}
proc args_get(buf: pointer; maxLen: int32): int32 {.importc, codegenDecl: hostImport("args_get").}
proc NimMain() {.importc, cdecl.}

proc getArgs*(): string =
  ## The argument string the shell passed (`cat notes.txt` → "notes.txt").
  var buf: array[128, char]
  let n = args_get(addr buf[0], int32(buf.len))
  for i in 0 ..< max(n, 0): result.add buf[i]

proc write*(s: string) =
  if s.len > 0: serial_write(unsafeAddr s[0], int32(s.len))

proc writeBytes*(p: pointer; n: int) =
  if n > 0: serial_write(p, int32(n))

proc exitApp*(code: int) = sip_exit(int32(code))

proc chanSend*(server: cstring; data: openArray[byte]) =
  ## Post to a server's channel (needs CapIpc).
  chan_send(server, unsafeAddr data[0], int32(data.len))

proc subscribe*(topic: cstring): int32 = event_subscribe(topic)

proc waitEvent*(token: int32; buf: var openArray[byte]): int =
  ## Block (bounded by the host) for one event; bytes received or -1.
  int(event_wait(token, addr buf[0], int32(buf.len)))

template nimixWasmMain*(body: untyped) =
  proc start() {.exportc: "_start".} =
    NimMain()   # module init: --noMain skips it (same rule as ELF apps)
    body
