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
import ../../fs/vfs
import ../../fs/metadata_db
import ../../core/serial

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

# ── VFS and B+ Tree Metadata ──────────────────────────────────────────────────

proc testVFSRouting() =
  var stripped: cstring
  let fatDrv = getDriver("/fat/test.txt", stripped)
  check("vfs_fat_driver_found", fatDrv != nil)
  checkEq("vfs_fat_name", fatDrv.name, "fatfs")
  checkEq("vfs_fat_stripped", $stripped, "test.txt")

  let lfsDrv = getDriver("/lfs/test.txt", stripped)
  check("vfs_lfs_driver_found", lfsDrv != nil)
  checkEq("vfs_lfs_name", lfsDrv.name, "littlefs")
  checkEq("vfs_lfs_stripped", $stripped, "test.txt")

  let extDrv = getDriver("/ext/test.txt", stripped)
  check("vfs_ext_driver_found", extDrv != nil)
  checkEq("vfs_ext_name", extDrv.name, "lwext4")
  checkEq("vfs_ext_stripped", $stripped, "test.txt")

proc testMetadataBPlusTree() =
  kprintln("metadata: testMetadataBPlusTree start")
  let db = initDB()
  kprintln("metadata: initDB done")
  
  db.insert("artist:Daft Punk:1", 101)
  kprintln("metadata: insert 1 done")
  dumpDB(db)
  db.insert("artist:Daft Punk:2", 102)
  kprintln("metadata: insert 2 done")
  dumpDB(db)
  db.insert("artist:Kraftwerk:1", 201)
  kprintln("metadata: insert 3 done")
  dumpDB(db)
  db.insert("title:Around the World:1", 101)
  kprintln("metadata: insert 4 done")
  dumpDB(db)
  
  var val: uint64
  let getOk = db.get("artist:Kraftwerk:1", val)
  kprintln("metadata: get done")
  check("db_get_exact", getOk)
  checkEq("db_val_exact", int(val), 201)
  
  dumpDB(db)
  
  let results = db.queryPrefix("artist:Daft Punk:")
  kprintln("metadata: queryPrefix done")
  defaultSerial.putString("metadata: results.len = ")
  defaultSerial.putInt(int64(results.len))
  defaultSerial.putChar('\n')
  checkEq("db_query_count", results.len, 2)
  checkEq("db_query_k0", results[0].key, "artist:Daft Punk:1")
  checkEq("db_query_v0", int(results[0].val), 101)
  checkEq("db_query_k1", results[1].key, "artist:Daft Punk:2")
  checkEq("db_query_v1", int(results[1].val), 102)
  
  let serialized = db.serializeDB()
  kprintln("metadata: serializeDB done")
  let db2 = deserializeDB(serialized)
  kprintln("metadata: deserializeDB done")
  
  dumpDB(db2)
  
  var val2: uint64
  let getOk2 = db2.get("artist:Kraftwerk:1", val2)
  check("db_deserialized_get", getOk2)
  checkEq("db_deserialized_val", int(val2), 201)
  
  let results2 = db2.queryPrefix("artist:Daft Punk:")
  checkEq("db_deserialized_query_count", results2.len, 2)

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
  testVFSRouting()
  testMetadataBPlusTree()

  testDone()
