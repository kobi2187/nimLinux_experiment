# SPDX-License-Identifier: GPL-2.0
## Tests for kernel trait interfaces
## Verifies types compile correctly and constants have expected values.

import ../kernel/config
import ../kernel/traits/scheduler as schedTrait
import ../kernel/traits/ipc as ipcTrait
import ../kernel/traits/driver
import ../kernel/models/monolithic

# Re-open scheduler names for existing tests
from ../kernel/traits/scheduler import TaskId, TaskState, SchedulerError,
  TaskPriority, TaskProc, SchedulerVTable,
  tsReady, tsRunning, tsBlocked, tsSleeping, tsZombie,
  seOk, seOutOfSlots, seInvalidTask, seNotBlocked, `==`

# Re-open ipc names for existing tests
from ../kernel/traits/ipc import ChannelId, Message, IpcResult, IpcVTable,
  mrOk, mrFull, mrEmpty, mrInvalid, mrTimeout, `==`

proc testSchedulerTypes() =
  let id1 = TaskId(1)
  let id2 = TaskId(2)
  assert id1 != id2, "TaskId must support equality"
  assert ord(tsReady)    == 0
  assert ord(tsRunning)  == 1
  assert ord(tsBlocked)  == 2
  assert ord(tsSleeping) == 3
  assert ord(tsZombie)   == 4
  assert ord(seOk) == 0
  echo "PASS: scheduler trait types correct"

proc testIpcTypes() =
  let ch1 = ChannelId(0)
  let ch2 = ChannelId(1)
  assert ch1 != ch2, "ChannelId must support equality"
  assert MessageSize > 0, "MessageSize must be positive"
  assert ord(mrOk) == 0
  assert sizeof(Message) > 0
  echo "PASS: ipc trait types correct"

proc testDriverTypes() =
  assert ord(drOk) == 0
  assert ord(drNotFound) == 1
  echo "PASS: driver trait types correct"

proc testConfig() =
  assert KernelModel.len > 0, "KernelModel must be non-empty string"
  assert MaxTasks > 0
  assert MaxChannels > 0
  assert MessageSize > 0
  echo "PASS: kernel config constants correct"
  echo "  KernelModel = ", KernelModel
  echo "  MaxTasks    = ", MaxTasks
  echo "  MaxChannels = ", MaxChannels
  echo "  MessageSize = ", MessageSize

proc testMonolithicInit() =
  initMonolithicModel()
  # Use module-qualified access to avoid `spawn` keyword conflict in Nim 2.x
  assert schedTrait.scheduler.spawn != nil, "scheduler.spawn must be wired after initMonolithicModel"
  assert ipcTrait.ipc.send != nil, "ipc.send must be wired after initMonolithicModel"
  echo "PASS: monolithic model init wires vtables"

when isMainModule:
  testSchedulerTypes()
  testIpcTypes()
  testDriverTypes()
  testConfig()
  testMonolithicInit()
  echo "All trait tests passed."
