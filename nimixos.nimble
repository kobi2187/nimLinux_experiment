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

# Tasks

task kernel, "Build the kernel":
  exec "nim c --os:any --gc:none -d:release -d:danger --noMain kernel/init/main.nim"

task debug, "Build kernel with debug info":
  exec "nim c --os:any --gc:none -d:debug --debuginfo --linedir:on kernel/init/main.nim"

task test, "Run unit tests":
  exec "nim c -r tests/all_tests.nim"

task docs, "Generate documentation":
  exec "nim doc --project --index:on --outdir:docs core/types.nim"
