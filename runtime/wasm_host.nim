# SPDX-License-Identifier: GPL-2.0
## WASM Host ABI — capability constants and host function signatures
##
## These are the functions a WASM module can import from "env".
## Each is only bound at load time if the SIP holds the matching capability.
##
## Capability constants match CAP_* in docs/ARCHITECTURE.md:
##   1 = serial, 2 = fs_read, 3 = fs_write, 4 = ipc, 5 = events, 6 = spawn

const
  CapSerial*   = 1'u64
  CapFsRead*   = 2'u64
  CapFsWrite*  = 3'u64
  CapIpc*      = 4'u64
  CapEvents*   = 5'u64
  CapSpawn*    = 6'u64

# ── wasm3 linkage types ─────────────────────────────────────────────────────
# wasm3 host functions receive (runtime, ctx) and return a M3Result (cstring).
# nil return = success; non-nil = error string.

type
  Wasm3Runtime = distinct pointer
  Wasm3ImportCtx = distinct pointer
  Wasm3HostFn* = proc(rt: Wasm3Runtime, ctx: Wasm3ImportCtx): cstring {.cdecl.}
