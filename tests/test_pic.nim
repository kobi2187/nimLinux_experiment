# SPDX-License-Identifier: GPL-2.0
## Tests for PIC 8259A — pure constant/logic tests, no hardware

import ../drivers/pic

proc testVectorMapping() =
  assert PicMasterOffset == 0x20'u8, "master offset must be 0x20"
  assert PicSlaveOffset  == 0x28'u8, "slave offset must be 0x28"
  assert irqToVector(0)  == 0x20'u8, "IRQ0 → 0x20"
  assert irqToVector(1)  == 0x21'u8, "IRQ1 → 0x21"
  assert irqToVector(7)  == 0x27'u8, "IRQ7 → 0x27"
  assert irqToVector(8)  == 0x28'u8, "IRQ8 → 0x28"
  assert irqToVector(15) == 0x2F'u8, "IRQ15 → 0x2F"
  echo "PASS: PIC vector mapping"

when isMainModule:
  testVectorMapping()
  echo "All PIC tests passed."
