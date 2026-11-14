# SPDX-License-Identifier: GPL-2.0
## Host tests for core/klog_ring (the `dmesg` buffer).

import std/unittest
import ../core/klog_ring

proc snapshot(): string =
  for c in klogRingChars(): result.add c

suite "klog ring":
  setup: klogRingClear()

  test "keeps what was written, in order":
    klogRingPut("[INFO]  boot\n")
    klogRingPut('x')
    check snapshot() == "[INFO]  boot\nx"
    check klogRingDropped() == 0

  test "hex and decimal formatting":
    klogRingPutHex(0x1100'u64); klogRingPut(' ')
    klogRingPutHex(0'u64); klogRingPut(' ')
    klogRingPutInt(-42); klogRingPut(' ')
    klogRingPutInt(low(int64))
    check snapshot() == "1100 0 -42 -9223372036854775808"

  test "wrap-around drops the oldest bytes":
    for i in 0 ..< KlogRingSize + 10:
      klogRingPut(char(ord('a') + i mod 26))
    let s = snapshot()
    check s.len == KlogRingSize
    check klogRingDropped() == 10
    check s[0] == char(ord('a') + 10 mod 26)
    check s[^1] == char(ord('a') + (KlogRingSize + 9) mod 26)

  test "nil cstring is ignored":
    klogRingPut(cstring(nil))
    check klogRingLen() == 0
