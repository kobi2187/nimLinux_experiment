# SPDX-License-Identifier: GPL-2.0
## The port contract (ipc/ports/contract.nim): the generated C header and the test vectors are the files checked
## into the repository. If a Nim wire type changes and they were not regenerated, this test fails and says how to fix it.
import std/[os, unittest, strutils]
import ../ipc/ports/contract

const Root = currentSourcePath().parentDir.parentDir

suite "port contract":
  test "libnimix/nimix_contract.h is what the generator makes now":
    let have = readFile(Root / "libnimix" / "nimix_contract.h")
    check have == generateHeader()
    if have != generateHeader(): echo "STALE: run `make gen-contract` and commit libnimix/nimix_contract.h"

  test "tests/libnimix/port_vectors.txt is what the generator makes now":
    let have = readFile(Root / "tests" / "libnimix" / "port_vectors.txt")
    check have == generateVectors()
    if have != generateVectors(): echo "STALE: run `make gen-contract` and commit tests/libnimix/port_vectors.txt"

  test "the header carries every message type (a missing struct would be a missing check)":
    let h = generateHeader()
    for needle in ["NimixKeyWire", "NimixMotionWire", "NimixButtonWire", "NimixWheelWire", "NimixLostWire",
                   "NimixPresentWire", "NimixSetModeWire", "NimixDisplayModesWire", "NimixDisplayInfoWire", "NimixInputInfo",
                   "NIMIX_InputKind_ikLost", "NIMIX_DisplayOp_doPresent", "NIMIX_PortKind_pkDisplay"]:
      check needle in h
    check h.count("_Static_assert") == 11            # one size check per struct

  test "vectors cover every event kind and every display request":
    let v = generateVectors()
    for kind in ["event key", "event motion", "event button", "event wheel", "event lost",
                 "request info", "request modes", "request setmode", "request present"]:
      check kind in v
