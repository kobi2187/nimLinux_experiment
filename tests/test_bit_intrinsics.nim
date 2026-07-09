# SPDX-License-Identifier: GPL-2.0
## Host-side test for bit manipulation hardware intrinsics
import arch/common/bit_intrinsics
import unittest

suite "Hardware Bit Intrinsics":
  test "countTrailingZeros":
    check countTrailingZeros(1'u64) == 0
    check countTrailingZeros(2'u64) == 1
    check countTrailingZeros(8'u64) == 3
    check countTrailingZeros(0x8000000000000000'u64) == 63

  test "popcount":
    check popcount(0'u64) == 0
    check popcount(1'u64) == 1
    check popcount(7'u64) == 3
    check popcount(0xF0F0F0F0F0F0F0F0'u64) == 32
    check popcount(high(uint64)) == 64

  test "findFirstFreeInWordOpt":
    check findFirstFreeInWordOpt(0'u64) == 0         # bit 0 is free (0)
    check findFirstFreeInWordOpt(1'u64) == 1         # bit 0 is set, bit 1 is free
    check findFirstFreeInWordOpt(3'u64) == 2         # bits 0,1 set, bit 2 is free
    check findFirstFreeInWordOpt(high(uint64)) == -1 # no free bits
    check findFirstFreeInWordOpt(0xFFFFFFFFFFFFFFFE'u64) == 0
