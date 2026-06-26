---
name: project-build-system
description: "NimixOS build system, ISO structure, task workflow, and how to navigate work"
metadata: 
  node_type: memory
  type: project
  originSessionId: 2aeec000-d2c7-4794-ad9a-e8cd0ef40956
---

## Build system

- `make` — full cycle: build all 3 kernels, create ISO, boot in QEMU
- `make build` — compile all 3 kernel models (`-d:kernelModel=monolithic/microkernel/sasos`)
- `make iso` — default ISO with monolithic kernel
- `make iso-all` — single ISO with GRUB menu listing all 3 kernel variants
- `make nim-apps` — compile PIE ELF userspace apps (`--os:standalone`, `--mm:arc`)
- `make disk-add-apps` — copy WASM + ELF apps to FAT16 disk image via mtools
- `make test` — host-side unit tests (no QEMU, `--mm:refc`)
- `make test-arc` — dispatcher/CPS tests (`--mm:arc`)
- `make test-qemu` — full integration test via `tests/qemu_harness.py`
- `make qemu-gui` — boot with VGA display
- `make qemu-debug` — GDB server on :1234

## Kernel model compile flag

`kernel/config.nim` defines `KernelModel` as a strdefine. Three invocations of nim with `-d:kernelModel=X` produce three binaries: `build/kernel-monolithic`, `build/kernel-sasos`, `build/kernel-microkernel`.

## Userspace apps

- WASM apps: `apps/ping/`, `apps/pingpong/` — compiled with clang wasm32
- ELF apps: `apps/nim/*/` — compiled with `--os:standalone --mm:arc`, linked against `build/nimix_abi_stub.o` (weak stub for nimixWrite/nimixExit/etc)
- Built ELFs: `build/apps/` — hello.elf, ping_server.elf, ps.elf, kill.elf, stats.elf, ls.elf, top.elf, dispatch_server.elf, fs_server.elf

## Task management

- Tool: **taskwarrior** (`task` CLI)
- Project tag: `nimixos`
- Layer tags: `layer0`–`layer9` encode dependency ordering (lower = more foundational)
- Other tags: module area (gui, drivers, dispatcher, fs, network, audio, etc.)
- Workflow: **create/complete freely** — add tasks as work is discovered, mark done when code lands
- 68 tasks currently; priority field (H/M/L) used but dependency graph (layers) drives execution order
- The leaf nodes in the dependency graph (tasks with no blocking dependencies at their layer) are the right ones to execute next

## Key paths

- Kernel entry: `kernel/init/main.nim`
- Model scaffold: `kernel/models/{monolithic,microkernel,sasos}.nim`
- Shared traits: `kernel/traits/{scheduler,ipc,driver,event}.nim`
- Kernel config: `kernel/config.nim`
- ABI stub: `kernel/abi/nimix_abi_stub.c`, `kernel/abi/nimix_abi.h`
- Tests: `tests/` — each file is a standalone host-runnable test
- Servers (ELF): `servers/ping/`, `servers/dispatch/` (planned), etc.
- Apps (Nim): `apps/nim/`
