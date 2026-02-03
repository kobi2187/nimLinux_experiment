# SPDX-License-Identifier: GPL-2.0
## Tests for Task-to-ExecutionModel Adapter
##
## Verifies that traditional Task system integrates seamlessly
## with ExecutionModel abstraction

import unittest
import ../sched/task_adapter
import ../sched/execution_model
import ../sched/thread_model
import ../sched/task_manager
import ../mm/heap_manager
import ../mm/virtual_manager
import ../core/types
import ./framework

# Helper function to create a simple virtual manager for tests
proc createTestVirtualManager*(): VirtualMemManager =
  ## Create a test virtual memory manager
  var vmm = VirtualMemManager()
  vmm

# Helper function to create a simple heap manager for tests
proc createTestHeapManager*(): HeapManager =
  ## Create a test heap manager
  var hm = HeapManager()
  hm

suite "State Conversion":

  test "TaskState to ExecutionState conversion":
    check taskStateToExecState(tsCreated) == esReady
    check taskStateToExecState(tsRunning) == esRunning
    check taskStateToExecState(tsReady) == esReady
    check taskStateToExecState(tsSleeping) == esBlocked
    check taskStateToExecState(tsWaiting) == esBlocked
    check taskStateToExecState(tsStopped) == esSuspended
    check taskStateToExecState(tsDead) == esTerminated

  test "ExecutionState to TaskState conversion":
    check execStateToTaskState(esReady) == tsReady
    check execStateToTaskState(esRunning) == tsRunning
    check execStateToTaskState(esSuspended) == tsStopped
    check execStateToTaskState(esBlocked) == tsSleeping
    check execStateToTaskState(esTerminated) == tsDead

  test "Priority conversions are reversible":
    let original: TaskPriority = 75

    let exec = taskPriorityToExecPriority(original)
    let back = execPriorityToTaskPriority(exec)

    check back == original

suite "Context Synchronization":

  test "Sync task context to unit":
    var adapter = TaskAdapter(
      task: Task(
        context: CpuContext(
          rsp: 0x1000,
          rbp: 0x2000,
          rip: 0x3000
        )
      ),
      unit: ExecutionUnit(
        context: ExecutionContext()
      )
    )

    adapter.syncContextTaskToUnit()

    check adapter.unit.context.rsp == 0x1000
    check adapter.unit.context.rbp == 0x2000
    check adapter.unit.context.rip == 0x3000

  test "Sync unit context to task":
    var adapter = TaskAdapter(
      task: Task(
        context: CpuContext()
      ),
      unit: ExecutionUnit(
        context: ExecutionContext(
          rsp: 0x4000,
          rbp: 0x5000,
          rip: 0x6000
        )
      )
    )

    adapter.syncContextUnitToTask()

    check adapter.task.context.rsp == 0x4000
    check adapter.task.context.rbp == 0x5000
    check adapter.task.context.rip == 0x6000

  test "Full context sync round-trip":
    var adapter = TaskAdapter(
      task: Task(
        context: CpuContext(
          rsp: 0x1000,
          rbp: 0x2000,
          rbx: 0x3000,
          r12: 0x4000,
          rip: 0x5000,
          rflags: 0x200
        )
      ),
      unit: ExecutionUnit(
        context: ExecutionContext()
      )
    )

    # Task → Unit
    adapter.syncContextTaskToUnit()
    check adapter.unit.context.rbx == 0x3000

    # Modify unit context
    adapter.unit.context.rsp = 0x7000

    # Unit → Task
    adapter.syncContextUnitToTask()
    check adapter.task.context.rsp == 0x7000

suite "State Synchronization":

  test "Sync task state to unit":
    var adapter = TaskAdapter(
      task: Task(state: tsRunning, priority: 50),
      unit: ExecutionUnit()
    )

    adapter.syncTaskToUnit()

    check adapter.unit.state == esRunning
    check adapter.unit.priority == ExecutionPriority(50)

  test "Sync unit state to task":
    var adapter = TaskAdapter(
      task: Task(),
      unit: ExecutionUnit(state: esBlocked, priority: ExecutionPriority(75))
    )

    adapter.syncUnitToTask()

    check adapter.task.state == tsSleeping
    check adapter.task.priority == 75

suite "Adapter Manager Basics":

  test "Create and use adapter manager":
    let vmm = createTestVirtualManager()
    let hm = createTestHeapManager()
    let taskMgr = newTaskManager(hm, vmm)
    let model = createThreadModelImpl()
    let manager = newTaskAdapterManager(taskMgr, model)

    check manager.taskMgr != nil
    check manager.model != nil
    check manager.getAdapterCount() == 0

  test "Get model information":
    let vmm = createTestVirtualManager()
    let hm = createTestHeapManager()
    let taskMgr = newTaskManager(hm, vmm)
    let model = createThreadModelImpl()
    let manager = newTaskAdapterManager(taskMgr, model)

    let name = manager.getModelName()
    check name == "Threads"

  test "Get model statistics":
    let vmm = createTestVirtualManager()
    let hm = createTestHeapManager()
    let taskMgr = newTaskManager(hm, vmm)
    let model = createThreadModelImpl()
    let manager = newTaskAdapterManager(taskMgr, model)

    let stats = manager.getModelStats()
    check stats.len > 0
    check "Threads" in stats or "Created" in stats

suite "Adapter Manager State Operations":

  test "Set task state":
    let vmm = createTestVirtualManager()
    let hm = createTestHeapManager()
    let taskMgr = newTaskManager(hm, vmm)
    let model = createThreadModelImpl()
    let manager = newTaskAdapterManager(taskMgr, model)

    var adapter = TaskAdapter(
      task: Task(state: tsReady),
      unit: ExecutionUnit(state: esReady),
      model: model
    )

    let result = manager.setTaskState(adapter, tsRunning)
    check result.isOk()
    check adapter.task.state == tsRunning

  test "Get task state":
    let vmm = createTestVirtualManager()
    let hm = createTestHeapManager()
    let taskMgr = newTaskManager(hm, vmm)
    let model = createThreadModelImpl()
    let manager = newTaskAdapterManager(taskMgr, model)

    var adapter = TaskAdapter(
      task: Task(state: tsRunning),
      unit: ExecutionUnit(state: esRunning),
      model: model
    )

    let state = manager.getTaskState(adapter)
    check state == tsRunning

suite "Adapter Queue Operations":

  test "Enqueue task":
    let vmm = createTestVirtualManager()
    let hm = createTestHeapManager()
    let taskMgr = newTaskManager(hm, vmm)
    let model = createThreadModelImpl()
    let manager = newTaskAdapterManager(taskMgr, model)

    var adapter = TaskAdapter(
      task: Task(),
      unit: ExecutionUnit(),
      model: model
    )

    let result = manager.enqueueTask(adapter)
    check result.isOk()

  test "Dequeue task":
    let vmm = createTestVirtualManager()
    let hm = createTestHeapManager()
    let taskMgr = newTaskManager(hm, vmm)
    let model = createThreadModelImpl()
    let manager = newTaskAdapterManager(taskMgr, model)

    var adapter = TaskAdapter(
      task: Task(),
      unit: ExecutionUnit(),
      model: model
    )

    discard manager.enqueueTask(adapter)
    let result = manager.dequeueTask(adapter)
    check result.isOk()

suite "Adapter Suspend/Resume":

  test "Suspend task":
    let vmm = createTestVirtualManager()
    let hm = createTestHeapManager()
    let taskMgr = newTaskManager(hm, vmm)
    let model = createThreadModelImpl()
    let manager = newTaskAdapterManager(taskMgr, model)

    var adapter = TaskAdapter(
      task: Task(state: tsRunning),
      unit: ExecutionUnit(state: esRunning),
      model: model
    )

    let result = manager.suspendTask(adapter)
    check result.isOk()
    check adapter.task.state == tsSleeping

  test "Resume task":
    let vmm = createTestVirtualManager()
    let hm = createTestHeapManager()
    let taskMgr = newTaskManager(hm, vmm)
    let model = createThreadModelImpl()
    let manager = newTaskAdapterManager(taskMgr, model)

    var adapter = TaskAdapter(
      task: Task(state: tsSleeping),
      unit: ExecutionUnit(state: esBlocked),
      model: model
    )

    let result = manager.resumeTask(adapter)
    check result.isOk()
    check adapter.task.state == tsReady

suite "Adapter Switching":

  test "Switch between tasks":
    let vmm = createTestVirtualManager()
    let hm = createTestHeapManager()
    let taskMgr = newTaskManager(hm, vmm)
    let model = createThreadModelImpl()
    let manager = newTaskAdapterManager(taskMgr, model)

    var adapter1 = TaskAdapter(
      task: Task(
        state: tsRunning,
        context: CpuContext(rsp: 0x1000)
      ),
      unit: ExecutionUnit(
        state: esRunning,
        context: ExecutionContext(rsp: 0x1000)
      ),
      model: model
    )

    var adapter2 = TaskAdapter(
      task: Task(
        state: tsReady,
        context: CpuContext(rsp: 0x2000)
      ),
      unit: ExecutionUnit(
        state: esReady,
        context: ExecutionContext(rsp: 0x2000)
      ),
      model: model
    )

    let result = manager.switchTasks(adapter1, adapter2)
    check result.isOk()

suite "Adapter Composability":

  test "Switch models with same adapter":
    let vmm = createTestVirtualManager()
    let hm = createTestHeapManager()
    let taskMgr = newTaskManager(hm, vmm)

    # Start with thread model
    var threadManager = newTaskAdapterManager(taskMgr, createThreadModelImpl())
    check threadManager.getModelName() == "Threads"

    # Switch to fiber model
    var fiberManager = newTaskAdapterManager(taskMgr, createFiberModelImpl())
    check fiberManager.getModelName() == "Fibers"

    # Switch to green thread model
    var gtManager = newTaskAdapterManager(taskMgr, createGreenThreadModelImpl())
    check gtManager.getModelName() == "Green Threads"
