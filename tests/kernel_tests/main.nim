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
import ../../drivers/tsc
import ../../arch/x86_64/cpu_primitives
# DEFERRED: VFS + metadata_db imports cause seq[string] corruption in kernel context (--os:any)
# Disabled for V10. Will be re-enabled in Milestone 2 after refactoring.
# import ../../fs/vfs
# import ../../fs/metadata_db
import ../../core/serial
import ../../core/log

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
  check("pid_assigned",            procTable.tasks[slot].pid == pid0)
  check("pid_monotonic",           procTable.nextPid > pid0)
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

# ── TSC clock ─────────────────────────────────────────────────────────────────

proc testTscCalibrated() =
  check("tsc_ready", tscReady())
  let hz = tscClock().hz
  check("tsc_hz_plausible", hz >= 100_000_000'u64 and hz <= 20_000_000_000'u64)

proc testTscMonotonic() =
  var last = tscNanos()
  var backwards = 0
  for _ in 0 ..< 2000:
    let n = tscNanos()
    if n < last: inc backwards
    last = n
  checkEq("tsc_monotonic", backwards, 0)

proc testTscMatchesPit() =
  ## The fine clock and the scheduler tick are independent counters (TSC vs the
  ## PIT's channel 0): one second of PIT ticks must measure one second of TSC
  ## time, within 1 %. Interrupts are off in this suite, so enable them for the
  ## sleep, exactly as the testMode flow does while it waits for user tests.
  const TickNs = 11931'u64 * 1_000_000_000'u64 div 1_193_182'u64   # PIT ch0 period at divisor 11931
  let me = int(procTable.current)
  # Start on a tick edge: the wake-up lands on one, so a start mid-tick would
  # measure between 99 and 100 tick periods (up to 1 % short).
  sti()
  let edge = pitTicks()
  while pitTicks() == edge: hlt()
  cli()
  let t0 = pitTicks()
  let n0 = tscNanos()
  procSleepUntil(me, t0 + 100)          # marks us blocked; the PIT handler wakes us
  sti()
  while procTable.tasks[me].state == ptsBlocked: hlt()
  cli()
  let ticks = pitTicks() - t0
  let ns = tscNanos() - n0
  let expected = ticks * TickNs
  klogInt(llInfo, "[TSC-TEST] pit ticks: ", int64(ticks))
  klogInt(llInfo, "[TSC-TEST] tsc ms: ", int64(ns div 1_000_000'u64))
  klogInt(llInfo, "[TSC-TEST] pit-expected ms: ", int64(expected div 1_000_000'u64))
  let diff = if ns > expected: ns - expected else: expected - ns
  check("tsc_sleep_ticks", ticks >= 100'u64)
  check("tsc_vs_pit_1pct", diff * 100'u64 <= expected)
  checkEq("tsc_sleep_ms_at_least", int(ns div 1_000_000'u64 >= 990'u64), 1)

# ── VFS and B+ Tree Metadata ──────────────────────────────────────────────────
# DEFERRED: Disabled for V10 due to seq[string] corruption in kernel context.
# Will be re-enabled after refactoring metadata_db to use fixed-size arrays.

# proc testVFSRouting() =
#   var stripped: cstring
#   let fatDrv = getDriver("/fat/test.txt", stripped)
#   check("vfs_fat_driver_found", fatDrv != nil)
#   checkEq("vfs_fat_name", fatDrv.name, "fatfs")
#   checkEq("vfs_fat_stripped", $stripped, "test.txt")
#
#   let lfsDrv = getDriver("/lfs/test.txt", stripped)
#   check("vfs_lfs_driver_found", lfsDrv != nil)
#   checkEq("vfs_lfs_name", lfsDrv.name, "littlefs")
#   checkEq("vfs_lfs_stripped", $stripped, "test.txt")
#
#   let extDrv = getDriver("/ext/test.txt", stripped)
#   check("vfs_ext_driver_found", extDrv != nil)
#   checkEq("vfs_ext_name", extDrv.name, "lwext4")
#   checkEq("vfs_ext_stripped", $stripped, "test.txt")

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

  testTscCalibrated()
  testTscMonotonic()
  testTscMatchesPit()
  # DEFERRED: VFS + metadata tests disabled for V10
  # testVFSRouting()
  # testMetadataBPlusTree()

  testDone()
