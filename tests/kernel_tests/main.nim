# SPDX-License-Identifier: GPL-2.0
## Kernel-space integration test ELF.
##
## Runs at boot in testMode (-d:testMode). Directly exercises kernel
## internals that ring-3 apps cannot reach. Uses the arrange→act→assert
## pattern: capture before-state, act, assert delta, teardown.
##
## Compiled with --os:any --mm:arc like the kernel itself.
## Output parsed by qemu_harness.py --structured.

import ../../tests/test_protocol
import ../../mm/region_allocator
import ../../kernel/cap/capability
import ../../kernel/process_table
import ../../ipc/server_chan
import ../../drivers/pit

# ── region allocator ──────────────────────────────────────────────────────────

proc testRegionAllocFree() =
  let before = regionUsedCount()
  let h = regionAlloc(RegionSize)
  check("region_alloc_valid",        regionValid(h))
  checkEq("region_used_incremented", regionUsedCount(), before + 1)
  regionFree(h)
  checkEq("region_used_restored",    regionUsedCount(), before)

proc testRegionInvalidHandle() =
  let bad = RegionHandle(-1)
  check("region_invalid_handle", not regionValid(bad))

proc testRegionReuse() =
  let h1 = regionAlloc(RegionSize)
  regionFree(h1)
  let h2 = regionAlloc(RegionSize)
  checkEq("region_slot_reused", int(h2), int(h1))
  regionFree(h2)

# ── capability ────────────────────────────────────────────────────────────────

proc testCapGrantCheck() =
  let tok = capGrant(99, capIpc)
  check("cap_grant_not_null",  not tok.isNull)
  check("cap_check_right",     capCheck(tok, capIpc))
  check("cap_wrong_right",     not capCheck(tok, capFs))
  capRevoke(tok)
  check("cap_revoked",         not capCheck(tok, capIpc))

proc testNullCapRejects() =
  check("null_cap_rejects", not capCheck(NullCap, capIpc))

proc testCapGrantRegion() =
  let h   = regionAlloc(RegionSize)
  let tok = capGrantRegion(int(h), 42, capMemRead)
  check("cap_region_not_null",  not tok.isNull)
  check("cap_region_memread",   capCheck(tok, capMemRead))
  capRevoke(tok)
  regionFree(h)

# ── process table ─────────────────────────────────────────────────────────────

proc dummyEntry() {.nimcall.} = discard

proc testProcSpawnKill() =
  let before = procTable.taskCount
  let pid0   = procTable.nextPid
  let slot   = procSpawn("test_task", dummyEntry, tcApp, 128)
  check("spawn_succeeds",          slot >= 0)
  checkEq("task_count_up",         procTable.taskCount, before + 1)
  check("pid_monotonic",           procTable.tasks[slot].pid > pid0)
  discard procKill(slot)
  checkEq("task_count_restored",   procTable.taskCount, before)

proc testProcKillUnknown() =
  check("kill_invalid_slot", not procKill(-1))

# ── ServerChan ────────────────────────────────────────────────────────────────

proc testServerChanRoundTrip() =
  var ch = serverChanCreate("test.chan")

  var msg: ServerMsg
  msg.len     = 5
  msg.data[0] = 0x48  # 'H'
  msg.data[1] = 0x65  # 'e'
  msg.data[2] = 0x6C  # 'l'
  msg.data[3] = 0x6C  # 'l'
  msg.data[4] = 0x6F  # 'o'

  check("chan_post_ok",    serverChanPost(ch, msg))
  let got = serverChanRecv(ch)
  check("chan_recv_some",  got.hasValue)
  checkEq("chan_recv_len", int(got.value.len), 5)
  checkEq("chan_recv_d0",  got.value.data[0], 0x48'u8)

proc testServerChanEmptyRecv() =
  var ch = serverChanCreate("test.empty")
  let got = serverChanRecv(ch)
  check("chan_empty_recv_none", not got.hasValue)

# ── Tick / sleep ──────────────────────────────────────────────────────────────

proc testPitTickAdvances() =
  let t0 = pitTicks()
  pitTick()
  pitTick()
  check("pit_tick_advances", pitTicks() >= t0 + 2)

# ── Entry point ───────────────────────────────────────────────────────────────

proc kernelTestMain*() =
  testSuiteStart("kernel_tests")

  testRegionAllocFree()
  testRegionInvalidHandle()
  testRegionReuse()

  testCapGrantCheck()
  testNullCapRejects()
  testCapGrantRegion()

  testProcSpawnKill()
  testProcKillUnknown()

  testServerChanRoundTrip()
  testServerChanEmptyRecv()

  testPitTickAdvances()

  testDone()
