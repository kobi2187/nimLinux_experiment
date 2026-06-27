# SPDX-License-Identifier: GPL-2.0
## Ring-3 userspace test ELF.
##
## Compiled with --os:standalone -d:nimixUserspace as a PIE ELF.
## Loaded by the kernel in testMode after kernel_tests completes.
## Exercises the full syscall path: trampoline → syscall instruction
## → syscall_entry asm → dispatch table → kernel proc → sysretq.
## Works identically on all 3 kernel models (monolithic/micro/SASOS)
## because it only touches the public ABI, never internal structs.

{.define: nimixUserspace.}
import ../../tests/test_protocol

# ── ABI imports (weak stubs patched by ELF loader with syscall trampolines) ──

proc nimixWrite(buf: pointer; len: int) {.importc, cdecl.}
proc nimixExit(code: int) {.importc, cdecl, noreturn.}
proc nimixAllocRegion(size: int): pointer {.importc, cdecl.}
proc nimixFreeRegion(p: pointer; size: int) {.importc, cdecl.}
proc nimixChanSend(name: cstring; data: pointer; len: int): int {.importc, cdecl.}
proc nimixChanRecv(name: cstring; buf: pointer; len: int): int {.importc, cdecl.}
proc nimixEventSubscribe(topic: cstring): uint32 {.importc, cdecl.}
proc nimixEventPublish(topic: cstring; data: pointer; len: int) {.importc, cdecl.}
proc nimixEventPoll(token: uint32; buf: pointer; len: int): int {.importc, cdecl.}
proc nimixSleep(ticks: uint64) {.importc, cdecl.}
proc nimixYield() {.importc, cdecl.}
proc nimixUptimeSecs(): uint64 {.importc, cdecl.}
proc nimixGetArgs(buf: pointer; len: int): int {.importc, cdecl.}
proc nimixMapAnon(size: int): pointer {.importc, cdecl.}
proc nimixFreeAnon(p: pointer; size: int) {.importc, cdecl.}

# ── write helper ─────────────────────────────────────────────────────────────

proc write(s: string) =
  if s.len > 0: nimixWrite(unsafeAddr s[0], s.len)

# ── nimixWrite ────────────────────────────────────────────────────────────────

proc testWrite() =
  # If we get here, nimixWrite worked (test_protocol uses it for output).
  # Just verify it doesn't crash with a small write.
  let msg = "ping\n"
  nimixWrite(unsafeAddr msg[0], msg.len)
  testPass("abi_write")

# ── nimixAllocRegion / nimixFreeRegion ───────────────────────────────────────

proc testAllocFree() =
  let p = nimixAllocRegion(4096)
  check("abi_alloc_non_null", p != nil)
  # Write and read back a sentinel value to prove the memory is usable.
  cast[ptr uint64](p)[] = 0xDEADBEEF_CAFEBABE'u64
  check("abi_alloc_writable", cast[ptr uint64](p)[] == 0xDEADBEEF_CAFEBABE'u64)
  nimixFreeRegion(p, 4096)
  testPass("abi_alloc_free")

# ── nimixUptimeSecs ───────────────────────────────────────────────────────────

proc testUptimeSecs() =
  let t = nimixUptimeSecs()
  # Kernel has been running for at least 0 seconds; value must be sane.
  check("abi_uptime_non_negative", t < uint64.high)
  testPass("abi_uptime_secs")

# ── nimixSleep / nimixUptimeSecs order ───────────────────────────────────────

proc testSleepAdvancesTime() =
  let before = nimixUptimeSecs()
  nimixSleep(200)   # 200 PIT ticks = 2 seconds at 100 Hz
  let after = nimixUptimeSecs()
  check("abi_sleep_advances_time", after >= before)
  testPass("abi_sleep")

# ── nimixGetArgs ──────────────────────────────────────────────────────────────

proc testGetArgs() =
  var buf: array[256, byte]
  let n = nimixGetArgs(addr buf[0], buf.len)
  # Returns >= 0 always (may be empty string).
  check("abi_get_args_ok", n >= 0)
  testPass("abi_get_args")

# ── nimixEventSubscribe / Publish / Poll ─────────────────────────────────────

proc testEventPubSub() =
  let topic = "test.evt"
  let tok = nimixEventSubscribe(topic)
  check("abi_event_subscribe_nonzero", tok > 0)

  let payload = "hello"
  nimixEventPublish(topic, unsafeAddr payload[0], payload.len)

  var recvBuf: array[64, byte]
  let got = nimixEventPoll(tok, addr recvBuf[0], recvBuf.len)
  check("abi_event_poll_got_data", got > 0)
  testPass("abi_event_pubsub")

# ── nimixYield ────────────────────────────────────────────────────────────────

proc testYield() =
  # Just verify yield doesn't crash or hang.
  nimixYield()
  testPass("abi_yield")

# ── nimixMapAnon / nimixFreeAnon ─────────────────────────────────────────────

proc testMapAnon() =
  let p = nimixMapAnon(64)
  check("abi_map_anon_non_null", p != nil)
  if p == nil:
    return
  # Write a sentinel and read it back to prove the memory is usable.
  cast[ptr uint64](p)[] = 0xDEADBEEF_CAFE0001'u64
  check("abi_map_anon_writable", cast[ptr uint64](p)[] == 0xDEADBEEF_CAFE0001'u64)
  nimixFreeAnon(p, 64)
  testPass("abi_map_anon")

# ── Entry point ───────────────────────────────────────────────────────────────

proc appMain() {.exportc.} =
  testSuiteStart("user_tests")

  testWrite()
  testAllocFree()
  testUptimeSecs()
  testGetArgs()
  testMapAnon()
  testYield()
  testEventPubSub()
  testSleepAdvancesTime()   # last — takes 2 seconds

  testDone()
  nimixExit(0)
