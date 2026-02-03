# SPDX-License-Identifier: GPL-2.0
## Tests for Execution Model Abstraction
##
## Verifies that all execution models implement the interface correctly
## and can be used interchangeably by the scheduler

import unittest
import ../sched/execution_model
import ../sched/thread_model
import ../sched/fiber_model
import ../sched/greenthread_model
import ../core/types
import ./framework

suite "Execution Model - Abstract Interface":

  test "Execution unit creation and destruction":
    let model = createThreadModelImpl()

    let unitResult = model.createUnit(ExecutionPriority(50))
    check unitResult.isOk()

    let unit = unitResult.value
    check unit.id >= 0
    check unit.state == esReady
    check unit.priority == 50

    let destroyResult = model.destroyUnit(unit)
    check destroyResult.isOk()

  test "State transitions":
    let model = createThreadModelImpl()
    let unitResult = model.createUnit(ExecutionPriority(50))
    let unit = unitResult.value

    # Ready → Running
    var result = model.setState(unit, esRunning)
    check result.isOk()
    check model.getState(unit) == esRunning

    # Running → Suspended
    result = model.setState(unit, esSuspended)
    check result.isOk()
    check model.getState(unit) == esSuspended

  test "Ready queue operations":
    let model = createThreadModelImpl()

    let unit1Result = model.createUnit(ExecutionPriority(50))
    let unit2Result = model.createUnit(ExecutionPriority(60))

    check unit1Result.isOk()
    check unit2Result.isOk()

    let unit1 = unit1Result.value
    let unit2 = unit2Result.value

    # Enqueue units
    var result = model.enqueueUnit(unit1)
    check result.isOk()

    result = model.enqueueUnit(unit2)
    check result.isOk()

    # Select next should return first enqueued
    let nextOption = model.selectNext()
    check nextOption.isSome()

    # Dequeue
    result = model.dequeueUnit(unit1)
    check result.isOk()

  test "Context save and restore":
    let model = createThreadModelImpl()
    let unitResult = model.createUnit(ExecutionPriority(50))
    let unit = unitResult.value

    var ctx = ExecutionContext(
      rsp: 0x1000,
      rip: 0x2000,
      rax: 0x42
    )

    # Save context
    var result = model.saveContext(unit, addr ctx)
    check result.isOk()

    # Modify context
    ctx.rsp = 0x3000
    ctx.rip = 0x4000

    # Restore context
    result = model.restoreContext(unit, addr ctx)
    check result.isOk()

    # Values should be restored
    check ctx.rsp == 0x1000
    check ctx.rip == 0x2000

  test "Yield operation":
    let model = createThreadModelImpl()
    let unitResult = model.createUnit(ExecutionPriority(50))
    let unit = unitResult.value

    let result = model.yield()
    check result.isOk()

  test "Suspend and resume":
    let model = createThreadModelImpl()
    let unitResult = model.createUnit(ExecutionPriority(50))
    let unit = unitResult.value

    # Suspend
    var result = model.suspend(unit)
    check result.isOk()
    check model.getState(unit) == esBlocked

    # Resume
    result = model.resume(unit)
    check result.isOk()
    check model.getState(unit) == esReady

suite "Thread Model":

  test "Thread model characteristics":
    check ThreadCharacteristics.preemptive == true
    check ThreadCharacteristics.stackRequired == true
    check ThreadCharacteristics.contextSwitchCost == 1000
    check ThreadCharacteristics.supportsSMP == true

  test "Create and destroy multiple threads":
    let model = createThreadModelImpl()
    var units: seq[ExecutionUnit] = @[]

    for i in 0..<5:
      let result = model.createUnit(ExecutionPriority(i))
      check result.isOk()
      units.add(result.value)

    for unit in units:
      let result = model.destroyUnit(unit)
      check result.isOk()

  test "Thread statistics":
    let model = createThreadModelImpl()

    for i in 0..<3:
      discard model.createUnit(ExecutionPriority(50))

    let stats = model.getStats()
    check "Created: 3" in stats
    check "Context Switches" in stats

suite "Fiber Model":

  test "Fiber model characteristics":
    check FiberCharacteristics.preemptive == false
    check FiberCharacteristics.stackRequired == true
    check FiberCharacteristics.contextSwitchCost == 100
    check FiberCharacteristics.supportsSMP == false

  test "Create multiple fibers":
    let model = createFiberModelImpl()
    var fibers: seq[ExecutionUnit] = @[]

    for i in 0..<10:
      let result = model.createUnit(ExecutionPriority(i mod 5))
      check result.isOk()
      fibers.add(result.value)

    check fibers.len == 10

  test "Fiber yields":
    let model = createFiberModelImpl()
    let fiberResult = model.createUnit(ExecutionPriority(50))
    let fiber = fiberResult.value

    for i in 0..<5:
      let result = model.yield()
      check result.isOk()

    let stats = model.getStats()
    check "Yields" in stats

suite "Green Thread Model":

  test "Green thread model characteristics":
    check GreenThreadCharacteristics.preemptive == false
    check GreenThreadCharacteristics.stackRequired == true
    check GreenThreadCharacteristics.contextSwitchCost == 50
    check GreenThreadCharacteristics.supportsSMP == false

  test "Create and manage green threads":
    let model = createGreenThreadModelImpl()
    var threads: seq[ExecutionUnit] = @[]

    for i in 0..<20:
      let result = model.createUnit(ExecutionPriority(i mod 10))
      check result.isOk()
      threads.add(result.value)

    # Enqueue all
    for thread in threads:
      let result = model.enqueueUnit(thread)
      check result.isOk()

    # Select and dequeue some
    let nextOption = model.selectNext()
    check nextOption.isSome()

    let next = nextOption.get
    let deqResult = model.dequeueUnit(next)
    check deqResult.isOk()

  test "Green thread queue management":
    let model = createGreenThreadModelImpl()

    let t1Result = model.createUnit(ExecutionPriority(50))
    let t2Result = model.createUnit(ExecutionPriority(40))

    let t1 = t1Result.value
    let t2 = t2Result.value

    discard model.enqueueUnit(t1)
    discard model.enqueueUnit(t2)

    # t2 has higher priority (lower number), should be selected first
    let nextOption = model.selectNext()
    check nextOption.isSome()
    let next = nextOption.get
    check next.priority < t1.priority

suite "Model Interchangeability":

  test "All models implement same interface":
    let threadModel = createThreadModelImpl()
    let fiberModel = createFiberModelImpl()
    let gtModel = createGreenThreadModelImpl()

    # All should have valid vtables
    check threadModel.vtable != nil
    check fiberModel.vtable != nil
    check gtModel.vtable != nil

    # All should have names
    check threadModel.vtable.name != nil
    check fiberModel.vtable.name != nil
    check gtModel.vtable.name != nil

  test "Switch between execution units":
    let model = createThreadModelImpl()

    let unit1Result = model.createUnit(ExecutionPriority(50))
    let unit2Result = model.createUnit(ExecutionPriority(50))

    let unit1 = unit1Result.value
    let unit2 = unit2Result.value

    # Set unit1 as running
    discard model.setState(unit1, esRunning)

    # Switch to unit2
    let result = model.switchTo(unit1, unit2)
    check result.isOk()

    # unit2 should now be running
    check model.getState(unit2) == esRunning

  test "Model statistics are available":
    let models = [
      createThreadModelImpl(),
      createFiberModelImpl(),
      createGreenThreadModelImpl()
    ]

    for model in models:
      let stats = model.getStats()
      check stats.len > 0
      check "Created" in stats or "statistics" in stats.toLower()

suite "Execution Model Comparison":

  test "Compare model characteristics":
    let comparison = compareModels()

    # Should mention all models
    check "Threads" in comparison
    check "Fibers" in comparison
    check "Green Threads" in comparison
    check "Async" in comparison

    # Should have timing info
    check "Context Switch Cost" in comparison
    check "cycles" in comparison

  test "Model selection based on requirements":
    # Choose fiber for high concurrency, non-preemptive
    if FiberCharacteristics.maxConcurrent > ThreadCharacteristics.maxConcurrent:
      check FiberCharacteristics.contextSwitchCost < ThreadCharacteristics.contextSwitchCost

    # Choose thread for SMP support
    check ThreadCharacteristics.supportsSMP == true
    check FiberCharacteristics.supportsSMP == false

    # Choose green thread for balance
    check GreenThreadCharacteristics.contextSwitchCost < ThreadCharacteristics.contextSwitchCost
    check GreenThreadCharacteristics.contextSwitchCost > AsyncCharacteristics.contextSwitchCost

suite "Execution Model Error Handling":

  test "Invalid state transitions":
    let model = createThreadModelImpl()
    let unitResult = model.createUnit(ExecutionPriority(50))
    let unit = unitResult.value

    # Set to running
    discard model.setState(unit, esRunning)

    # Try to set to running again - should fail
    let result = model.setState(unit, esRunning)
    check result.isErr()
    check result.error == eeuAlreadyRunning

  test "Dequeue non-existent unit":
    let model = createThreadModelImpl()

    let unitResult = model.createUnit(ExecutionPriority(50))
    let unit = unitResult.value

    # Try to dequeue without enqueueing - should fail
    let result = model.dequeueUnit(unit)
    check result.isErr()
    check result.error == eeuNotRunning

  test "Resume non-blocked unit":
    let model = createThreadModelImpl()
    let unitResult = model.createUnit(ExecutionPriority(50))
    let unit = unitResult.value

    # Unit is in ready state, not blocked
    let result = model.resume(unit)
    check result.isErr()
    check result.error == eeuInvalidState
