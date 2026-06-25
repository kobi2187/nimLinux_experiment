# SPDX-License-Identifier: GPL-2.0
# Package

version       = "0.1.0"
author        = "NimixOS Contributors"
description   = "NimixOS - A Nim-based operating system kernel"
license       = "GPL-2.0"
srcDir        = "."
bin           = @["kernel/init/main"]

# Dependencies

requires "nim >= 2.0.0"
requires "https://github.com/kobi2187/arsenal"
requires "msgpack4nim >= 0.4.0"
requires "cps >= 0.11.0"

# Tasks

task kernel, "Build the kernel":
  exec "nim c --os:any --mm:arc -d:StandaloneHeapSize=16777216 -d:release -d:danger --noMain --outdir:build kernel/init/main.nim"

task debug, "Build kernel with debug info":
  exec "nim c --os:any --mm:arc -d:StandaloneHeapSize=16777216 -d:debug --debuginfo --linedir:on kernel/init/main.nim"

task iso, "Create a bootable ISO image":
  exec "nimble kernel"
  exec "mkdir -p iso/boot/grub"
  exec "cp build/main iso/boot/kernel.elf"
  exec "echo 'menuentry \"NimixOS\" { multiboot2 /boot/kernel.elf }' > iso/boot/grub/grub.cfg"
  exec "grub-mkrescue -o nimixos.iso iso/"
  exec "rm -rf iso"

task run, "Boot kernel in QEMU with serial output":
  exec "nimble iso"
  exec "qemu-system-x86_64 -cdrom nimixos.iso -serial stdio -no-reboot -m 256M"

task test, "Run unit tests":
  exec "nim c -r tests/all_tests.nim"

task docs, "Generate documentation":
  exec "nim doc --project --index:on --outdir:docs core/types.nim"
