# SPDX-License-Identifier: GPL-2.0
## Tests for the Microkernel kernel model
##
## Verifies: priority scheduler, service registry, double-copy IPC,
## and that the vtable wiring produces a usable kernel interface.

import kernel/models/microkernel
import kernel/traits/scheduler as schedTrait
import kernel/traits/ipc as ipcTrait
import core/types

# ── Test helpers ────────────────────────────────────────────────────────────

var passed = 0
var failed = 0

proc check(name: string, cond: bool) =
  if cond:
    echo "PASS: ", name
    inc passed
  else:
    echo "FAIL: ", name
    inc failed

proc dummyTask() {.nimcall.} = discard

# ═══════════════════════════════════════════════════════════════════════════
# Priority Mapping
# ═══════════════════════════════════════════════════════════════════════════

block:
  check("priority 255 → Critical", toMkPriority(TaskPriority(255)) == mkCritical)
  check("priority 200 → Critical", toMkPriority(TaskPriority(200)) == mkCritical)
  check("priority 192 → Critical", toMkPriority(TaskPriority(192)) == mkCritical)
  check("priority 191 → High",     toMkPriority(TaskPriority(191)) == mkHigh)
  check("priority 128 → High",     toMkPriority(TaskPriority(128)) == mkHigh)
  check("priority 127 → Normal",   toMkPriority(TaskPriority(127)) == mkNormal)
  check("priority 64  → Normal",   toMkPriority(TaskPriority(64))  == mkNormal)
  check("priority 63  → Low",      toMkPriority(TaskPriority(63))  == mkLow)
  check("priority 0   → Low",      toMkPriority(TaskPriority(0))   == mkLow)

# ═══════════════════════════════════════════════════════════════════════════
# VTable Wiring
# ═══════════════════════════════════════════════════════════════════════════

block:
  initMicrokernelModel()
  check("scheduler.spawn is set",     schedTrait.scheduler.spawn != nil)
  check("scheduler.yield is set",     schedTrait.scheduler.`yield` != nil)
  check("scheduler.blockTask is set", schedTrait.scheduler.blockTask != nil)
  check("scheduler.wake is set",      schedTrait.scheduler.wake != nil)
  check("scheduler.current is set",   schedTrait.scheduler.current != nil)
  check("scheduler.exit is set",      schedTrait.scheduler.exit != nil)
  check("ipc.send is set",            ipcTrait.ipc.send != nil)
  check("ipc.recv is set",            ipcTrait.ipc.recv != nil)
  check("ipc.open is set",            ipcTrait.ipc.open != nil)
  check("ipc.close is set",           ipcTrait.ipc.close != nil)

# ═══════════════════════════════════════════════════════════════════════════
# Priority Scheduler
# ═══════════════════════════════════════════════════════════════════════════

block:
  initMicrokernelModel()

  # Spawn tasks at different priorities
  let lowTask  = schedTrait.scheduler.spawn(dummyTask, TaskPriority(10))   # Low
  let normTask = schedTrait.scheduler.spawn(dummyTask, TaskPriority(100))  # Normal
  let highTask = schedTrait.scheduler.spawn(dummyTask, TaskPriority(200))  # Critical

  check("spawn low priority",      lowTask.isOk)
  check("spawn normal priority",   normTask.isOk)
  check("spawn critical priority", highTask.isOk)

  # Yield should pick highest priority (Critical) first
  schedTrait.scheduler.`yield`()
  let cur = schedTrait.scheduler.current()
  check("yield picks critical task first", cur == highTask.value)

  # Block critical, yield should pick normal
  let blockRes = schedTrait.scheduler.blockTask(highTask.value)
  check("block critical succeeds", blockRes.isOk)
  schedTrait.scheduler.`yield`()
  let cur2 = schedTrait.scheduler.current()
  check("yield picks normal after critical blocked", cur2 == normTask.value)

  # Block normal, yield should pick low
  discard schedTrait.scheduler.blockTask(normTask.value)
  schedTrait.scheduler.`yield`()
  let cur3 = schedTrait.scheduler.current()
  check("yield picks low when others blocked", cur3 == lowTask.value)

  # Wake critical, yield should go back to critical
  let wakeRes = schedTrait.scheduler.wake(highTask.value)
  check("wake critical succeeds", wakeRes.isOk)
  schedTrait.scheduler.`yield`()
  let cur4 = schedTrait.scheduler.current()
  check("yield picks woken critical task", cur4 == highTask.value)

# ═══════════════════════════════════════════════════════════════════════════
# Service Registry
# ═══════════════════════════════════════════════════════════════════════════

block:
  initMicrokernelModel()

  # Open channels for services
  let ch1 = ipcTrait.ipc.open()
  let ch2 = ipcTrait.ipc.open()
  check("open service channel 1", ch1.isOk)
  check("open service channel 2", ch2.isOk)

  # Register named services
  let reg1 = mkServiceRegister("vfs", ch1.value, TaskId(0))
  let reg2 = mkServiceRegister("kbd", ch2.value, TaskId(1))
  check("register vfs service", reg1)
  check("register kbd service", reg2)

  # Look up services by name
  let found1 = mkServiceLookup("vfs")
  let found2 = mkServiceLookup("kbd")
  let notFound = mkServiceLookup("net")
  check("lookup vfs → correct channel",   found1 == ch1.value)
  check("lookup kbd → correct channel",   found2 == ch2.value)
  check("lookup net → not found",         notFound == ChannelId(uint32.high))

# ═══════════════════════════════════════════════════════════════════════════
# Double-Copy IPC
# ═══════════════════════════════════════════════════════════════════════════

block:
  initMicrokernelModel()

  let ch = ipcTrait.ipc.open()
  check("ipc open succeeds", ch.isOk)

  # Send a message
  var msg: Message
  msg.sender = TaskId(0)
  msg.size   = 5
  msg.data[0] = byte('H')
  msg.data[1] = byte('e')
  msg.data[2] = byte('l')
  msg.data[3] = byte('l')
  msg.data[4] = byte('o')

  let sendRes = ipcTrait.ipc.send(ch.value, addr msg)
  check("ipc send succeeds", sendRes == mrOk)

  # Receive it back
  var recvMsg: Message
  let recvRes = ipcTrait.ipc.recv(ch.value, addr recvMsg)
  check("ipc recv succeeds",      recvRes == mrOk)
  check("recv data matches sent", recvMsg.data[0] == byte('H') and
                                   recvMsg.data[4] == byte('o'))

  # Close channel
  let closeRes = ipcTrait.ipc.close(ch.value)
  check("ipc close succeeds", closeRes == mrOk)

  # Send to closed channel fails
  let failSend = ipcTrait.ipc.send(ch.value, addr msg)
  check("send to closed channel fails", failSend == mrInvalid)

# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════

echo ""
if failed == 0:
  echo "All microkernel model tests passed. (", passed, " checks)"
else:
  echo "FAILED: ", failed, " of ", passed + failed, " checks"
  quit(1)
