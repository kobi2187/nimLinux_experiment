# SPDX-License-Identifier: GPL-2.0
## PCI BAR (Base Address Register) Decode.
##
## Each BAR holds either an MMIO or I/O base address.
## Size is determined by the "size probe" trick: write all-ones, read back,
## mask the type bits, invert, add 1.  The original value is restored
## so the device continues to function during enumeration.
##
## 64-bit MMIO BARs span two consecutive BAR slots (type bits 2:1 = 0b10).

import pci_config

const
  BarRegBase    = 0x10'u8   # BAR0 config register offset
  BarRegStep    = 4'u8      # each BAR is one dword apart
  BarIoBit      = 0x01'u32  # bit 0: 1 = I/O space, 0 = MMIO
  BarMmio64Bits = 0x04'u32  # bits 2:1 = 0b10 → 64-bit address
  BarPrefetch   = 0x08'u32  # bit 3: prefetchable

type
  BarKind* = enum barMmio, barIo
  Bar* = object
    kind*:         BarKind
    base*:         uint64
    size*:         uint64
    prefetchable*: bool

proc barReg(barIndex: int): uint8 {.inline.} =
  BarRegBase + uint8(barIndex) * BarRegStep

proc probeBarSize(bus, slot, fn: uint8; reg: uint8): uint32 =
  ## Write all-ones, read back, restore.  Returns raw readback.
  let orig = pciConfigReadU32(bus, slot, fn, reg)
  pciConfigWriteU32(bus, slot, fn, reg, 0xFFFFFFFF'u32)
  let probe = pciConfigReadU32(bus, slot, fn, reg)
  pciConfigWriteU32(bus, slot, fn, reg, orig)
  probe

proc pciBarDecode*(bus, slot, fn: uint8; barIndex: int): Bar =
  ## Decode one BAR.  For 64-bit MMIO bars the next slot provides
  ## the high 32 bits of both base and size.
  let reg  = barReg(barIndex)
  let val  = pciConfigReadU32(bus, slot, fn, reg)
  let isIo = (val and BarIoBit) != 0

  if isIo:
    result.kind = barIo
    result.base = uint64(val and 0xFFFFFFFC'u32)
    let probe = probeBarSize(bus, slot, fn, reg)
    let masked = probe and 0xFFFFFFFC'u32
    result.size = if masked == 0: 0 else: uint64(not masked) + 1
    result.prefetchable = false
  else:
    result.kind = barMmio
    result.prefetchable = (val and BarPrefetch) != 0
    let is64 = (val and BarMmio64Bits) == BarMmio64Bits

    let probeLo = probeBarSize(bus, slot, fn, reg)
    let maskedLo = probeLo and 0xFFFFFFF0'u32

    if is64:
      let regHi   = reg + BarRegStep
      let valHi   = pciConfigReadU32(bus, slot, fn, regHi)
      let probeHi = probeBarSize(bus, slot, fn, regHi)
      result.base = (uint64(valHi) shl 32) or uint64(val and 0xFFFFFFF0'u32)
      let raw64 = (uint64(probeHi) shl 32) or uint64(maskedLo)
      let maskedFull = raw64 and 0xFFFFFFFFFFFFFFF0'u64
      result.size = if maskedFull == 0: 0 else: (not maskedFull) + 1
    else:
      result.base = uint64(val and 0xFFFFFFF0'u32)
      result.size = if maskedLo == 0: 0 else: uint64(not maskedLo) + 1
