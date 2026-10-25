# SPDX-License-Identifier: GPL-2.0
## WASM Runner — load and execute WASM modules via wasm3
##
## Correct wasm3 API order:
##   ParseModule → LoadModule → LinkRawFunction(s) → FindFunction → CallV
##
## Host function signature (M3RawCall):
##   proc(rt, ctx, sp: ptr uint64[], mem: pointer) -> pointer  (nil = ok)
##   Args are on the WASM stack (sp[0], sp[1], ...) as uint64.

import ./wasm_build        # {.compile.} directives for wasm3 C sources
import ./wasm_host         # CapSerial, CapIpc, etc.
import ../core/log
import ../core/serial
import ../ipc/sip_chan
import ../kernel/event_server
import ../kernel/traits/event
import ../drivers/pit      # pitTicks() for timeout
import ../servers/ping_server  # pingServerTick() called in event_wait

# ── wasm3 opaque types ────────────────────────────────────────────────────────

type
  M3Env      {.importc: "IM3Environment", header: "wasm3.h".} = distinct pointer
  M3Runtime  {.importc: "IM3Runtime",     header: "wasm3.h".} = distinct pointer
  M3Module   {.importc: "IM3Module",      header: "wasm3.h".} = distinct pointer
  M3Function {.importc: "IM3Function",    header: "wasm3.h".} = distinct pointer
  M3Result                                                     = cstring
  M3Stack    = ptr UncheckedArray[uint64]
  # M3RawCall: the type wasm3 expects for raw host functions
  M3RawCall  = proc(rt: M3Runtime, ctx: pointer,
                    sp: M3Stack, mem: pointer): pointer {.cdecl.}

# ── wasm3 C API ───────────────────────────────────────────────────────────────

{.passC: "-I" & currentSourcePath()[0 .. ^("runtime/wasm_runner.nim".len + 1)] &
  "vendor/wasm3/source".}

proc m3_NewEnvironment(): M3Env
  {.importc: "m3_NewEnvironment", header: "wasm3.h".}

proc m3_NewRuntime(env: M3Env, stackSize: uint32, userData: pointer): M3Runtime
  {.importc: "m3_NewRuntime", header: "wasm3.h".}

proc m3_ParseModule(env: M3Env, outMod: ptr M3Module,
                    bytes: ptr uint8, numBytes: uint32): M3Result
  {.importc: "m3_ParseModule", header: "wasm3.h".}

proc m3_LoadModule(rt: M3Runtime, module: M3Module): M3Result
  {.importc: "m3_LoadModule", header: "wasm3.h".}

proc m3_LinkRawFunction(module: M3Module, modName, fnName, sig: cstring,
                        fn: M3RawCall): M3Result
  {.importc: "m3_LinkRawFunction", header: "wasm3.h".}

proc m3_FindFunction(outFn: ptr M3Function, rt: M3Runtime, name: cstring): M3Result
  {.importc: "m3_FindFunction", header: "wasm3.h".}

proc m3_CallV(fn: M3Function): M3Result
  {.importc: "m3_CallV", header: "wasm3.h".}

proc m3_GetMemory(rt: M3Runtime, outSize: ptr uint32, memIdx: uint32): ptr uint8
  {.importc: "m3_GetMemory", header: "wasm3.h".}

type M3ErrorInfo {.importc: "M3ErrorInfo", header: "wasm3.h".} = object
  result   {.importc: "result".}:  cstring
  file     {.importc: "file".}:    cstring
  line     {.importc: "line".}:    uint32

proc m3_GetErrorInfo(rt: M3Runtime, info: ptr M3ErrorInfo)
  {.importc: "m3_GetErrorInfo", header: "wasm3.h".}

proc logWasm3Error(rt: M3Runtime, phase: cstring) =
  var info: M3ErrorInfo
  m3_GetErrorInfo(rt, addr info)
  defaultSerial.putString("[wasm3] ")
  defaultSerial.putString(phase)
  defaultSerial.putString(": ")
  if info.result != nil: defaultSerial.putString(info.result)
  if info.file   != nil:
    defaultSerial.putString(" (")
    defaultSerial.putString(info.file)
    defaultSerial.putChar(':')
    defaultSerial.putInt(int64(info.line))
    defaultSerial.putChar(')')
  defaultSerial.putChar('\n')

# ── Host functions (M3RawCall signature) ─────────────────────────────────────
# Args from WASM stack: sp[0] = first arg, sp[1] = second, etc. (uint64)
# Return nil for success, non-nil cstring for error.

var gRuntime: M3Runtime  ## set per-run so host fns can call m3_GetMemory

proc hostSerialWrite(rt: M3Runtime, ctx: pointer,
                     sp: M3Stack, mem: pointer): pointer {.cdecl, exportc.} =
  ## env.serial_write(ptr: i32, len: i32) — write WASM linear memory to serial
  let memPtr = uint32(sp[0])
  let memLen = uint32(sp[1])
  var size: uint32
  let wasmMem = m3_GetMemory(rt, addr size, 0)
  if wasmMem != nil and memPtr + memLen <= size:
    let src = cast[ptr UncheckedArray[char]](wasmMem)
    for i in 0..<int(memLen):
      defaultSerial.putChar(src[int(memPtr) + i])
  nil

proc hostChanSend(rt: M3Runtime, ctx: pointer,
                  sp: M3Stack, mem: pointer): pointer {.cdecl, exportc.} =
  ## env.chan_send(name_ptr: i32, data_ptr: i32, data_len: i32)
  let namePtr = uint32(sp[0])
  let dataPtr = uint32(sp[1])
  let dataLen = uint32(sp[2])
  var size: uint32
  let wasmMem = m3_GetMemory(rt, addr size, 0)
  if wasmMem != nil and namePtr < size and dataPtr + dataLen <= size:
    let name = cast[cstring](cast[uint64](wasmMem) + uint64(namePtr))
    let data = cast[ptr byte](cast[uint64](wasmMem) + uint64(dataPtr))
    discard sipChanSend(name, data, int(dataLen))
  nil

proc hostSipExit(rt: M3Runtime, ctx: pointer,
                 sp: M3Stack, mem: pointer): pointer {.cdecl, exportc.} =
  ## env.sip_exit(code: i32)
  klog(llInfo, "WASM sip_exit")
  nil

proc hostEventSubscribe(rt: M3Runtime, ctx: pointer,
                        sp: M3Stack, mem: pointer): pointer {.cdecl, exportc.} =
  ## env.event_subscribe(topic_ptr: i32) -> i32 (token, 0 = error)
  ## Stack layout for (i32)->i32: sp[0]=return slot, sp[1]=arg0
  let topicPtr = uint32(sp[1])  # arg after return slot
  var size: uint32
  let wasmMem = m3_GetMemory(rt, addr size, 0)
  if wasmMem == nil or topicPtr >= size:
    sp[0] = 0
    return nil
  let topic = cast[cstring](cast[uint64](wasmMem) + uint64(topicPtr))
  let token = eventSubscribe(topic)
  sp[0] = uint64(uint32(token))  # write return value to sp[0]
  nil

proc hostEventWait(rt: M3Runtime, ctx: pointer,
                   sp: M3Stack, mem: pointer): pointer {.cdecl, exportc.} =
  ## env.event_wait(token: i32, buf_ptr: i32, max_len: i32) -> i32
  ## Stack layout for (i32,i32,i32)->i32: sp[0]=return, sp[1]=token, sp[2]=buf, sp[3]=maxlen
  let token   = EventToken(uint32(sp[1]))
  let bufPtr  = uint32(sp[2])
  let maxLen  = uint32(sp[3])

  var size: uint32
  let wasmMem = m3_GetMemory(rt, addr size, 0)
  if wasmMem == nil or bufPtr + maxLen > size:
    sp[0] = 0xFFFFFFFF'u64  # -1 as i32
    return nil

  let deadline = pitTicks() + 500  # 500 ticks @ 100Hz = 5 seconds
  while pitTicks() < deadline:
    pingServerTick()
    let ev = eventPoll(token)
    if ev.isSome:
      let payload = ev.get().payload
      let copyLen = if uint32(payload.len) < maxLen: uint32(payload.len) else: maxLen
      let dst = cast[ptr UncheckedArray[byte]](
        cast[uint64](wasmMem) + uint64(bufPtr))
      for i in 0..<int(copyLen):
        dst[i] = payload.data[i]
      sp[0] = uint64(copyLen)  # return bytes written
      return nil

  sp[0] = 0xFFFFFFFF'u64  # timeout: return -1 as i32
  nil

# ── Result type ───────────────────────────────────────────────────────────────

type
  WasmResult* = enum
    wasmOk
    wasmEnvError    ## Failed to create wasm3 environment/runtime
    wasmParseError  ## Bytecode parse failed
    wasmLinkError   ## Module load failed
    wasmNoEntry     ## No _start or main function found
    wasmRunError    ## Runtime error during execution

# ── Public API ────────────────────────────────────────────────────────────────

proc wasmRun*(wasmBytes: ptr byte, wasmLen: int,
              caps: openArray[uint64] = []): WasmResult =
  ## Load and run a WASM module from a byte array.
  ## Binds only host functions whose capability is in `caps`.
  ## Calls _start() as the entry point.

  let env = m3_NewEnvironment()
  if pointer(env) == nil:
    klog(llError, "wasm3: NewEnvironment failed")
    return wasmEnvError

  let rt = m3_NewRuntime(env, 8192, nil)
  if pointer(rt) == nil:
    klog(llError, "wasm3: NewRuntime failed")
    return wasmEnvError
  gRuntime = rt

  var module: M3Module
  let parseErr = m3_ParseModule(env, addr module,
                                cast[ptr uint8](wasmBytes), uint32(wasmLen))
  if parseErr != nil:
    defaultSerial.putString("[wasm3] parse: ")
    defaultSerial.putString(parseErr)
    defaultSerial.putChar('\n')
    return wasmParseError

  let loadErr = m3_LoadModule(rt, module)
  if loadErr != nil:
    logWasm3Error(rt, "load")
    return wasmLinkError

  # Link host functions after LoadModule
  # Always available
  discard m3_LinkRawFunction(module, "env", "serial_write",    "v(ii)",  hostSerialWrite)
  discard m3_LinkRawFunction(module, "env", "sip_exit",        "v(i)",   hostSipExit)
  discard m3_LinkRawFunction(module, "env", "event_subscribe", "i(i)",   hostEventSubscribe)
  discard m3_LinkRawFunction(module, "env", "event_wait",      "i(iii)", hostEventWait)
  # Capability-gated
  for c in caps:
    if c == CapIpc:
      discard m3_LinkRawFunction(module, "env", "chan_send", "v(iii)", hostChanSend)
      break

  var startFn: M3Function
  var findErr = m3_FindFunction(addr startFn, rt, "_start")
  if findErr != nil:
    findErr = m3_FindFunction(addr startFn, rt, "main")
    if findErr != nil:
      klog(llError, "wasm3: no _start or main")
      return wasmNoEntry

  let callErr = m3_CallV(startFn)
  if callErr != nil:
    logWasm3Error(rt, "call")
    return wasmRunError

  wasmOk
