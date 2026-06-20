# SPDX-License-Identifier: GPL-2.0
## Tests for TSS constants — no hardware

import ../arch/x86_64/tss

proc testSelectors() =
  assert KernelCS == 0x08'u16, "kernel CS must be 0x08"
  assert KernelDS == 0x10'u16, "kernel DS must be 0x10"
  assert UserCS   == 0x1B'u16, "user CS must be 0x18 | 3 (RPL=3)"
  assert UserDS   == 0x23'u16, "user DS must be 0x20 | 3 (RPL=3)"
  assert TssSelector == 0x28'u16, "TSS selector must be 0x28"
  echo "PASS: GDT selectors"

proc testTssSize() =
  assert sizeof(Tss) == 104, "TSS must be exactly 104 bytes per spec"
  echo "PASS: TSS struct size"

when isMainModule:
  testSelectors()
  testTssSize()
  echo "All TSS tests passed."
