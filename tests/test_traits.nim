# SPDX-License-Identifier: GPL-2.0
## Tests for kernel trait interfaces
## Verifies types compile correctly and constants have expected values.

import ../kernel/config
import ../kernel/traits/scheduler
import ../kernel/traits/ipc
import ../kernel/traits/driver

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

when isMainModule:
  testSchedulerTypes()
  testIpcTypes()
  testDriverTypes()
  testConfig()
  echo "All trait tests passed."
