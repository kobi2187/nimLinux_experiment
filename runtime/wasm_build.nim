# SPDX-License-Identifier: GPL-2.0
## wasm3 C compilation directives
##
## Included by wasm_runner.nim. Tells Nim's C backend to compile wasm3
## source files alongside the kernel using freestanding-compatible flags.
##
## Key flags:
##   d_m3FixedHeap   — wasm3 uses a static arena instead of malloc/free
##   d_m3HasFloat=0  — disable float ops (saves ~20KB, we don't need them yet)
##   d_m3VerboseErrorMessages=0 — no printf in error paths

# Repo-relative: strip "runtime/wasm_build.nim" off this file's absolute path.
const wasm3Src = currentSourcePath()[0 .. ^("runtime/wasm_build.nim".len + 1)] &
  "vendor/wasm3/source"
const wasm3Flags = "-I" & wasm3Src &
  " -Dd_m3HasFloat=0" &
  " -Dd_m3VerboseErrorMessages=0" &
  " -Dd_m3MaxFunctionStackHeight=512" &
  " -ffreestanding -fno-stack-protector -mno-red-zone -mcmodel=kernel -fno-pic"

{.passC: wasm3Flags.}

{.compile: "../vendor/wasm3/source/m3_bind.c".}
{.compile: "../vendor/wasm3/source/m3_code.c".}
{.compile: "../vendor/wasm3/source/m3_compile.c".}
{.compile: "../vendor/wasm3/source/m3_core.c".}
{.compile: "../vendor/wasm3/source/m3_env.c".}
{.compile: "../vendor/wasm3/source/m3_exec.c".}
{.compile: "../vendor/wasm3/source/m3_function.c".}
{.compile: "../vendor/wasm3/source/m3_module.c".}
{.compile: "../vendor/wasm3/source/m3_parse.c".}
