# SPDX-License-Identifier: GPL-2.0
## Tests for driver registry — no hardware needed

import ../kernel/driver_registry
import ../kernel/traits/driver

# Build two fake drivers for testing
var initCalled  = 0
var deinitCalled = 0

proc fakeInit(): DriverResult {.nimcall.} =
  inc initCalled
  drOk

proc fakeDeinit(): DriverResult {.nimcall.} =
  inc deinitCalled
  drOk

proc failInit(): DriverResult {.nimcall.} =
  inc initCalled
  drNotFound

let fakeDriver = DriverVTable(
  name:   "fake_driver",
  init:   fakeInit,
  deinit: fakeDeinit,
  irq:    nil
)

let failDriver = DriverVTable(
  name:   "fail_driver",
  init:   failInit,
  deinit: fakeDeinit,
  irq:    nil
)

proc testRegisterAndProbe() =
  resetRegistry()
  initCalled = 0

  registerDriver(unsafeAddr fakeDriver)
  registerDriver(unsafeAddr failDriver)

  let (ok, fail) = probeAllDrivers()
  assert ok   == 1, "one driver should succeed"
  assert fail == 1, "one driver should fail"
  assert initCalled == 2, "init called on both drivers"
  echo "PASS: register and probe"

proc testRegistryFull() =
  resetRegistry()
  # Fill the registry to capacity
  for i in 0..<32:
    registerDriver(unsafeAddr fakeDriver)
  # One more should be ignored (no crash)
  registerDriver(unsafeAddr fakeDriver)
  let (ok, _) = probeAllDrivers()
  assert ok == 32, "exactly 32 drivers probed"
  echo "PASS: registry capacity limit"

when isMainModule:
  testRegisterAndProbe()
  testRegistryFull()
  echo "All driver registry tests passed."
