import unittest
import ../kernel/module_loader

suite "Module Loader Registry":

  setup:
    resetRegistry()

  test "registers module":
    var initCalled = false
    var deinitCalled = false

    let info = ModuleInfo(
      name: "test_module",
      version: 0x00010000'u32,
      class: mcFilesystem,
      init: proc(): bool {.nimcall.} =
        initCalled = true
        true,
      deinit: proc() {.nimcall.} =
        deinitCalled = true
    )

    registerModule(addr info)
    check registryCount() == 1

  test "load all modules calls init":
    var initCount = 0

    let info = ModuleInfo(
      name: "test",
      version: 0x00010000'u32,
      class: mcDriver,
      init: proc(): bool {.nimcall.} =
        inc initCount
        true,
      deinit: proc() {.nimcall.} = discard
    )

    registerModule(addr info)
    let (ok, fail) = loadAllModules()

    check initCount == 1
    check ok == 1
    check fail == 0

  test "load all modules returns (ok, fail) count":
    var init1Called = false
    var init2Called = false

    let info1 = ModuleInfo(
      name: "module1",
      version: 0x00010000'u32,
      class: mcDriver,
      init: proc(): bool {.nimcall.} =
        init1Called = true
        true,
      deinit: proc() {.nimcall.} = discard
    )

    let info2 = ModuleInfo(
      name: "module2",
      version: 0x00010000'u32,
      class: mcDriver,
      init: proc(): bool {.nimcall.} =
        init2Called = true
        false,  # This one fails
      deinit: proc() {.nimcall.} = discard
    )

    registerModule(addr info1)
    registerModule(addr info2)
    let (ok, fail) = loadAllModules()

    check init1Called
    check init2Called
    check ok == 1
    check fail == 1

  test "load all modules stops on max":
    let MaxMods = 16
    for i in 0..<MaxMods + 5:
      let info = ModuleInfo(
        name: ("mod" & $i).cstring,
        version: 0x00010000'u32,
        class: mcDriver,
        init: proc(): bool {.nimcall.} = true,
        deinit: proc() {.nimcall.} = discard
      )
      registerModule(addr info)

    check registryCount() == MaxMods  # capped

  test "module class enum exists":
    check mcFilesystem == ModuleClass.mcFilesystem
    check mcDriver == ModuleClass.mcDriver
    check mcServer == ModuleClass.mcServer
    check mcOther == ModuleClass.mcOther

  test "reset registry clears all":
    let info = ModuleInfo(
      name: "test",
      version: 0x00010000'u32,
      class: mcDriver,
      init: proc(): bool {.nimcall.} = true,
      deinit: proc() {.nimcall.} = discard
    )

    registerModule(addr info)
    check registryCount() == 1

    resetRegistry()
    check registryCount() == 0

  test "init order is registration order":
    var callOrder: seq[int]

    let info1 = ModuleInfo(
      name: "first",
      version: 0x00010000'u32,
      class: mcDriver,
      init: proc(): bool {.nimcall.} =
        callOrder.add(1)
        true,
      deinit: proc() {.nimcall.} = discard
    )

    let info2 = ModuleInfo(
      name: "second",
      version: 0x00010000'u32,
      class: mcDriver,
      init: proc(): bool {.nimcall.} =
        callOrder.add(2)
        true,
      deinit: proc() {.nimcall.} = discard
    )

    registerModule(addr info1)
    registerModule(addr info2)
    discard loadAllModules()

    check callOrder == @[1, 2]
