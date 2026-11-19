# SPDX-License-Identifier: GPL-2.0
## Writes the two generated files of the port contract (see ipc/ports/contract.nim).
##   gen_contract header <path>     libnimix/nimix_contract.h
##   gen_contract vectors <path>    tests/libnimix/port_vectors.txt
import std/os
import ../ipc/ports/contract

when isMainModule:
  if paramCount() != 2 or paramStr(1) notin ["header", "vectors"]:
    quit("usage: gen_contract header|vectors <path>", 2)
  writeFile(paramStr(2), if paramStr(1) == "header": generateHeader() else: generateVectors())
