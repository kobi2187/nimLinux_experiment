# SPDX-License-Identifier: GPL-2.0
## Tests for named capability registry (no hardware needed)

import ../kernel/cap/cap_registry
import ../kernel/cap/capability

proc testCapRegisterSucceeds() =
  capTableInit()
  capRegistryInit()
  let ok = capRegister("ipc.echo", capIpc)
  assert ok, "capRegister must succeed for a new name"
  echo "PASS: capRegister succeeds for new name"

proc testCapRegisterFailsDuplicate() =
  capTableInit()
  capRegistryInit()
  discard capRegister("ipc.echo", capIpc)
  let ok = capRegister("ipc.echo", capFs)
  assert not ok, "capRegister must fail for duplicate name"
  echo "PASS: capRegister fails for duplicate name"

proc testCapRequestReturnsNonNull() =
  capTableInit()
  capRegistryInit()
  discard capRegister("fs.root", capFs)
  let tok = capRequest("fs.root", 42)
  assert not isNull(tok), "capRequest for registered name must return non-null token"
  echo "PASS: capRequest for registered name returns non-null token"

proc testCapRequestUnknownReturnsNullCap() =
  capTableInit()
  capRegistryInit()
  let tok = capRequest("unknown.cap", 1)
  assert isNull(tok), "capRequest for unknown name must return NullCap"
  echo "PASS: capRequest for unknown name returns NullCap"

proc testCapUnregisterRemovesEntry() =
  capTableInit()
  capRegistryInit()
  discard capRegister("net.raw", capNet)
  let ok = capUnregister("net.raw")
  assert ok, "capUnregister must return true for existing entry"
  echo "PASS: capUnregister removes the entry"

proc testCapRequestAfterUnregisterReturnsNullCap() =
  capTableInit()
  capRegistryInit()
  discard capRegister("net.raw", capNet)
  discard capUnregister("net.raw")
  let tok = capRequest("net.raw", 1)
  assert isNull(tok), "capRequest after unregister must return NullCap"
  echo "PASS: capRequest after unregister returns NullCap"

proc testCapRegisterTableFull() =
  capTableInit()
  capRegistryInit()
  for i in 0 ..< MaxNamedCaps:
    var name = "cap." & $i
    discard capRegister(name, capIpc)
  # One more should fail
  let ok = capRegister("cap.overflow", capIpc)
  assert not ok, "capRegister on full table must return false"
  echo "PASS: capRegister returns false when table is full"

when isMainModule:
  testCapRegisterSucceeds()
  testCapRegisterFailsDuplicate()
  testCapRequestReturnsNonNull()
  testCapRequestUnknownReturnsNullCap()
  testCapUnregisterRemovesEntry()
  testCapRequestAfterUnregisterReturnsNullCap()
  testCapRegisterTableFull()
  echo "All cap_registry tests passed."
