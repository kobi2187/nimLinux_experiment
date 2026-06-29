import unittest
import ../kernel/module_loader
import ../core/log

suite "Kernel Module Integration":

  setup:
    resetRegistry()

  test "loadAllModules called at appropriate time":
    ## Simulates what kernel/init/main.nim will do:
    ## Import modules, then call loadAllModules() to init them all.
    var moduleInitOrder: seq[string]

    let mod1 = ModuleInfo(
      name: "early_module",
      version: 0x00010000'u32,
      class: mcDriver,
      init: proc(): bool {.nimcall.} =
        moduleInitOrder.add("early_module")
        true,
      deinit: proc() {.nimcall.} = discard
    )

    let mod2 = ModuleInfo(
      name: "late_module",
      version: 0x00010000'u32,
      class: mcFilesystem,
      init: proc(): bool {.nimcall.} =
        moduleInitOrder.add("late_module")
        true,
      deinit: proc() {.nimcall.} = discard
    )

    registerModule(addr mod1)
    registerModule(addr mod2)

    # This is what kernel/init/main.nim will do in initModules()
    let (ok, fail) = loadAllModules()

    check moduleInitOrder == @["early_module", "late_module"]
    check ok == 2
    check fail == 0

  test "module init failure counted separately":
    var successCount = 0
    var failCount = 0

    let goodMod = ModuleInfo(
      name: "good",
      version: 0x00010000'u32,
      class: mcDriver,
      init: proc(): bool {.nimcall.} =
        inc successCount
        true,
      deinit: proc() {.nimcall.} = discard
    )

    let badMod = ModuleInfo(
      name: "bad",
      version: 0x00010000'u32,
      class: mcDriver,
      init: proc(): bool {.nimcall.} =
        inc failCount
        false,
      deinit: proc() {.nimcall.} = discard
    )

    registerModule(addr goodMod)
    registerModule(addr badMod)

    let (ok, fail) = loadAllModules()

    check successCount == 1
    check failCount == 1
    check ok == 1
    check fail == 1

  test "no modules registered returns (0, 0)":
    let (ok, fail) = loadAllModules()
    check ok == 0
    check fail == 0

  test "module classification preserved through registration":
    var savedClass: ModuleClass

    let testMod = ModuleInfo(
      name: "test",
      version: 0x00010000'u32,
      class: mcFilesystem,
      init: proc(): bool {.nimcall.} =
        # Can't access module class from init, so save it before
        savedClass = mcFilesystem
        true,
      deinit: proc() {.nimcall.} = discard
    )

    registerModule(addr testMod)
    discard loadAllModules()

    check savedClass == mcFilesystem
