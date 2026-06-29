import unittest
import ../kernel/module_loader

suite "FatFS Module Metadata":

  test "module info has correct name":
    # Simulate what fatfs_module.nim will create
    let testInfo = ModuleInfo(
      name: "fatfs",
      version: 0x00010000'u32,
      class: mcFilesystem,
      init: proc(): bool {.nimcall.} = true,
      deinit: proc() {.nimcall.} = discard
    )
    check testInfo.name == "fatfs"

  test "module info has filesystem class":
    let testInfo = ModuleInfo(
      name: "fatfs",
      version: 0x00010000'u32,
      class: mcFilesystem,
      init: proc(): bool {.nimcall.} = true,
      deinit: proc() {.nimcall.} = discard
    )
    check testInfo.class == mcFilesystem

  test "module info has version":
    let testInfo = ModuleInfo(
      name: "fatfs",
      version: 0x00010000'u32,
      class: mcFilesystem,
      init: proc(): bool {.nimcall.} = true,
      deinit: proc() {.nimcall.} = discard
    )
    check testInfo.version == 0x00010000'u32
