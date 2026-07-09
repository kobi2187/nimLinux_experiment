# SPDX-License-Identifier: GPL-2.0
## CPU Bit Manipulation Hardware Intrinsics
## ==========================================
##
## Wraps GCC/Clang built-in intrinsics to map directly to single-cycle CPU instructions
## (e.g. tzcnt/bsf for count-trailing-zeros, and popcnt for bit count).
## High-performance helpers for physical memory page tables/allocators.

# GCC/Clang built-in function imports
proc builtin_ctzll(x: culonglong): cint {.importc: "__builtin_ctzll", nodecl.}
proc builtin_popcountll(x: culonglong): cint {.importc: "__builtin_popcountll", nodecl.}

proc countTrailingZeros*(word: uint64): int {.inline.} =
  ## Returns number of trailing zeros in a non-zero 64-bit integer.
  ## Undefined behaviour if word == 0.
  if word == 0: return 0
  int(builtin_ctzll(cast[culonglong](word)))

proc popcount*(word: uint64): int {.inline.} =
  ## Returns number of set bits (1s) in a 64-bit integer.
  int(builtin_popcountll(cast[culonglong](word)))

proc findFirstFreeInWordOpt*(word: uint64): int {.inline.} =
  ## Scans a 64-bit integer for the first unset bit (0).
  ## Returns its 0-indexed position, or -1 if all bits are set.
  if word == high(uint64):
    return -1
  # Invert the word to locate the first zero as a set bit
  let inverted = not word
  countTrailingZeros(inverted)
