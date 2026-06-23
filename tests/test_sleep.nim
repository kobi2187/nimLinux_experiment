# SPDX-License-Identifier: GPL-2.0
## Unit tests for procSleepUntil / procWakeExpired (no hardware needed)
## Compile with: nim c -r --skipParentCfg --mm:refc --path:. -d:noSignalHandler -d:testing tests/test_sleep.nim

import ../kernel/process_table

proc resetTable() =
  procTableInit()

proc spawnTask(name: cstring): int =
  procSpawn(name, nil, tcApp, 0)

proc testStillBlockedBeforeWakeTime() =
  resetTable()
  let slot = spawnTask("sleeper")
  assert slot >= 0, "spawn failed"
  mockTicks = 50
  procSleepUntil(slot, 100)
  assert procTable.tasks[slot].state == ptsBlocked, "task should be blocked"
  assert procTable.tasks[slot].wakeAt == 100, "wakeAt should be 100"
  # now = 99, should stay blocked
  mockTicks = 99
  procWakeExpired(procTable)
  assert procTable.tasks[slot].state == ptsBlocked, "task must stay blocked at tick 99"
  echo "PASS: task stays blocked when now < wakeAt"

proc testWokenAtExactTick() =
  resetTable()
  let slot = spawnTask("sleeper2")
  assert slot >= 0, "spawn failed"
  mockTicks = 50
  procSleepUntil(slot, 100)
  assert procTable.tasks[slot].state == ptsBlocked
  # now = 100, should wake
  mockTicks = 100
  procWakeExpired(procTable)
  assert procTable.tasks[slot].state == ptsReady, "task must be ready at tick 100"
  assert procTable.tasks[slot].wakeAt == 0, "wakeAt must be cleared"
  # task should be back in the ring (head for tcApp)
  assert procTable.heads[int(tcApp)] == int16(slot), "task must be in ring after wake"
  echo "PASS: task woken at exact wakeAt tick"

proc testWokenAfterWakeTime() =
  resetTable()
  let slot = spawnTask("sleeper3")
  assert slot >= 0, "spawn failed"
  mockTicks = 10
  procSleepUntil(slot, 100)
  # now = 200 (past wakeAt)
  mockTicks = 200
  procWakeExpired(procTable)
  assert procTable.tasks[slot].state == ptsReady, "task must be ready when now > wakeAt"
  echo "PASS: task woken when now > wakeAt"

proc testZeroWakeAtNotWoken() =
  resetTable()
  let slot = spawnTask("blocked")
  assert slot >= 0, "spawn failed"
  # Manually block the task with wakeAt = 0 (not a sleep, just blocked for IPC)
  procTable.tasks[slot].state  = ptsBlocked
  procTable.tasks[slot].wakeAt = 0
  # Remove from ring manually since we set blocked without going through procSleepUntil
  ringRemove(procTable, int16(slot), int(tcApp))
  mockTicks = 9999
  procWakeExpired(procTable)
  assert procTable.tasks[slot].state == ptsBlocked, "task with wakeAt=0 must not be woken"
  echo "PASS: task with wakeAt=0 not woken by procWakeExpired"

testStillBlockedBeforeWakeTime()
testWokenAtExactTick()
testWokenAfterWakeTime()
testZeroWakeAtNotWoken()
echo "All sleep tests passed."
