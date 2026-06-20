# SPDX-License-Identifier: GPL-2.0
## Tests for the SASOS kernel model
##
## Verifies: SIP registry, capability system, capability-gated IPC,
## SIP-aware scheduling, and vtable wiring.

import kernel/models/sasos
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
# VTable Wiring
# ═══════════════════════════════════════════════════════════════════════════

block:
  initSasosModel()
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
# SIP Registry
# ═══════════════════════════════════════════════════════════════════════════

block:
  initSasosModel()

  # Kernel SIP should be created automatically
  check("kernel SIP created (sipCount=1)", sipCount == 1)
  check("currentSip is kernel (SipId 0)",  currentSip == SipId(0))

  # Create additional SIPs
  let appSip = sasosCreateSip("myapp")
  check("create app SIP succeeds", appSip != SipId(uint32.high))
  check("sipCount is now 2", sipCount == 2)

  let driverSip = sasosCreateSip("driver.net")
  check("create driver SIP succeeds", driverSip != SipId(uint32.high))
  check("sipCount is now 3", sipCount == 3)

# ═══════════════════════════════════════════════════════════════════════════
# Capability System
# ═══════════════════════════════════════════════════════════════════════════

block:
  initSasosModel()

  let appSip = sasosCreateSip("testapp")

  # App starts with no channel capabilities
  check("app has no cap initially", not sasosHasCapability(appSip, capChannelRead, 0))

  # Grant read+write on channel 0
  let g1 = sasosGrantCapability(appSip, capChannelRead, 0)
  let g2 = sasosGrantCapability(appSip, capChannelWrite, 0)
  check("grant read cap", g1)
  check("grant write cap", g2)
  check("app now has read cap",  sasosHasCapability(appSip, capChannelRead, 0))
  check("app now has write cap", sasosHasCapability(appSip, capChannelWrite, 0))

  # App does NOT have cap for channel 1
  check("app has no cap for ch1", not sasosHasCapability(appSip, capChannelRead, 1))

  # Revoke read cap
  let rev = sasosRevokeCapability(appSip, capChannelRead, 0)
  check("revoke read cap succeeds", rev)
  check("app lost read cap",  not sasosHasCapability(appSip, capChannelRead, 0))
  check("app still has write cap", sasosHasCapability(appSip, capChannelWrite, 0))

# ═══════════════════════════════════════════════════════════════════════════
# Capability-Gated IPC — Kernel SIP (has all caps via auto-grant)
# ═══════════════════════════════════════════════════════════════════════════

block:
  initSasosModel()
  # currentSip = kernel SIP (0)

  # Open a channel — kernel SIP gets auto-granted read+write
  let ch = ipcTrait.ipc.open()
  check("kernel can open channel", ch.isOk)

  # Kernel SIP should be able to send and recv
  var msg: Message
  msg.sender = TaskId(0)
  msg.size   = 3
  msg.data[0] = byte('A')
  msg.data[1] = byte('B')
  msg.data[2] = byte('C')

  let sendRes = ipcTrait.ipc.send(ch.value, addr msg)
  check("kernel can send (has cap)", sendRes == mrOk)

  var recvMsg: Message
  let recvRes = ipcTrait.ipc.recv(ch.value, addr recvMsg)
  check("kernel can recv (has cap)", recvRes == mrOk)
  check("recv data matches", recvMsg.data[0] == byte('A'))

# ═══════════════════════════════════════════════════════════════════════════
# Capability-Gated IPC — Unprivileged SIP (denied without caps)
# ═══════════════════════════════════════════════════════════════════════════

block:
  initSasosModel()

  # Open channel as kernel
  let ch = ipcTrait.ipc.open()
  check("open channel as kernel", ch.isOk)

  # Create unprivileged SIP and switch to it
  let appSip = sasosCreateSip("unprivileged")
  sasosSetCurrentSip(appSip)

  # Send should fail — app has no write cap
  var msg: Message
  msg.sender = TaskId(0)
  msg.size   = 1
  msg.data[0] = byte('X')
  let sendFail = ipcTrait.ipc.send(ch.value, addr msg)
  check("unprivileged send denied", sendFail == mrInvalid)

  # Recv should also fail — app has no read cap
  var recvMsg: Message
  let recvFail = ipcTrait.ipc.recv(ch.value, addr recvMsg)
  check("unprivileged recv denied", recvFail == mrInvalid)

  # Now grant write cap to app
  discard sasosGrantCapability(appSip, capChannelWrite, uint32(ch.value))
  let sendOk = ipcTrait.ipc.send(ch.value, addr msg)
  check("send succeeds after grant", sendOk == mrOk)

  # Recv still fails (only write granted)
  let recvStillFail = ipcTrait.ipc.recv(ch.value, addr recvMsg)
  check("recv still denied (no read cap)", recvStillFail == mrInvalid)

  # Grant read cap
  discard sasosGrantCapability(appSip, capChannelRead, uint32(ch.value))
  let recvOk = ipcTrait.ipc.recv(ch.value, addr recvMsg)
  check("recv succeeds after read grant", recvOk == mrOk)

# ═══════════════════════════════════════════════════════════════════════════
# SIP-Aware Scheduling
# ═══════════════════════════════════════════════════════════════════════════

block:
  initSasosModel()
  # currentSip starts as kernel (0)

  let appSip = sasosCreateSip("scheduled-app")

  # Spawn a task while currentSip = kernel
  let t1 = schedTrait.scheduler.spawn(dummyTask, TaskPriority(100))
  check("spawn task as kernel SIP", t1.isOk)

  # Switch to app SIP and spawn another
  sasosSetCurrentSip(appSip)
  let t2 = schedTrait.scheduler.spawn(dummyTask, TaskPriority(50))
  check("spawn task as app SIP", t2.isOk)

  # Yield should switch task and update currentSip accordingly
  schedTrait.scheduler.`yield`()
  # After yield, currentSip should reflect the task's owning SIP
  # (either kernel's task or app's task, depending on round-robin)
  let curId = schedTrait.scheduler.current()
  check("yield selects a valid task", curId == t1.value or curId == t2.value)

# ═══════════════════════════════════════════════════════════════════════════
# Channel Close Revokes Caps
# ═══════════════════════════════════════════════════════════════════════════

block:
  initSasosModel()

  let ch = ipcTrait.ipc.open()
  check("open channel for close test", ch.isOk)

  # Kernel has caps (auto-granted by open)
  check("kernel has write cap before close",
        sasosHasCapability(SipId(0), capChannelWrite, uint32(ch.value)))

  # Close channel — should revoke all caps
  let closeRes = ipcTrait.ipc.close(ch.value)
  check("close succeeds", closeRes == mrOk)
  check("write cap revoked after close",
        not sasosHasCapability(SipId(0), capChannelWrite, uint32(ch.value)))
  check("read cap revoked after close",
        not sasosHasCapability(SipId(0), capChannelRead, uint32(ch.value)))

# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════

echo ""
if failed == 0:
  echo "All SASOS model tests passed. (", passed, " checks)"
else:
  echo "FAILED: ", failed, " of ", passed + failed, " checks"
  quit(1)
