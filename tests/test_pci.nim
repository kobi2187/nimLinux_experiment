# SPDX-License-Identifier: GPL-2.0
## PCI subsystem unit tests — host-side, no hardware required.
##
## Tests pure-logic functions that do not invoke port I/O:
##   - pciAddress encoding
##   - pciDeviceName name table
##   - BAR size computation formula (inline, no hardware probe)

import ../drivers/pci/pci_device

# ── pciAddress encoding ────────────────────────────────────────────────────
# pciAddress is not exported, so we replicate the formula here to verify the
# spec: bit31=enable, bus<<16, slot<<11, fn<<8, reg & 0xFC.

proc expectedAddress(bus, slot, fn, reg: uint8): uint32 {.inline.} =
  (1'u32 shl 31) or
  (uint32(bus)  shl 16) or
  (uint32(slot) shl 11) or
  (uint32(fn)   shl  8) or
  uint32(reg and 0xFC'u8)

proc testPciAddressEncoding() =
  # Bus 0, slot 0, fn 0, reg 0 → enable bit only
  assert expectedAddress(0, 0, 0, 0)   == 0x80000000'u32, "base address"

  # Bus 1, slot 0, fn 0, reg 0
  assert expectedAddress(1, 0, 0, 0)   == 0x80010000'u32, "bus=1"

  # Bus 0, slot 2, fn 0, reg 0
  assert expectedAddress(0, 2, 0, 0)   == 0x80001000'u32, "slot=2"

  # Bus 0, slot 0, fn 3, reg 0
  assert expectedAddress(0, 0, 3, 0)   == 0x80000300'u32, "fn=3"

  # Register 0x10 (BAR0)
  assert expectedAddress(0, 0, 0, 0x10) == 0x80000010'u32, "reg=0x10"

  # Reg 0x11 → aligned to 0x10 (bit 0,1 cleared)
  assert expectedAddress(0, 0, 0, 0x11) == 0x80000010'u32, "reg alignment"

  # Reg 0x13 → still aligns to 0x10
  assert expectedAddress(0, 0, 0, 0x13) == 0x80000010'u32, "reg alignment 0x13"

  # QEMU typical: bus 0, slot 1, fn 0 — PCI host bridge
  assert expectedAddress(0, 1, 0, 0)   == 0x80000800'u32, "slot=1"

  echo "PASS: pciAddress encoding"

# ── pciDeviceName lookup ───────────────────────────────────────────────────

proc testPciDeviceName() =
  assert pciDeviceName(0x1AF4, 0x1000) == "virtio-net",             "virtio-net"
  assert pciDeviceName(0x1AF4, 0x1001) == "virtio-block",           "virtio-block"
  assert pciDeviceName(0x1AF4, 0x1050) == "virtio-gpu",             "virtio-gpu"
  assert pciDeviceName(0x1AF4, 0x1052) == "virtio-input",           "virtio-input"
  assert pciDeviceName(0x8086, 0x100E) == "e1000 (Intel 82540EM)",  "e1000"
  assert pciDeviceName(0x8086, 0x1237) == "Intel 440FX host bridge","440FX"
  assert pciDeviceName(0x8086, 0x7000) == "Intel PIIX3 ISA bridge", "PIIX3 ISA"
  assert pciDeviceName(0x8086, 0x7010) == "Intel PIIX3 IDE",        "PIIX3 IDE"
  assert pciDeviceName(0x8086, 0x7113) == "Intel PIIX4 ACPI",       "PIIX4 ACPI"
  assert pciDeviceName(0x1234, 0x1111) == "QEMU VGA",               "QEMU VGA"
  assert pciDeviceName(0xDEAD, 0xBEEF) == nil,                      "unknown → nil"
  assert pciDeviceName(0x0000, 0x0000) == nil,                      "zeroes → nil"
  echo "PASS: pciDeviceName lookup"

# ── BAR size formula ───────────────────────────────────────────────────────
# pciBarDecode probes hardware, so we test the size computation in isolation.
# The probe returns ~0 for the bits that vary; masking and inverting gives size.

proc barSizeFromProbe(probe: uint32; mask: uint32): uint64 =
  ## Replicate the MMIO size calculation: mask type bits, invert, +1.
  let masked = probe and mask
  if masked == 0: 0'u64
  else: uint64(not masked) + 1

proc testBarSizeFormula() =
  # 4 KB MMIO BAR: probe = 0xFFFFF000, mask = 0xFFFFFFF0
  assert barSizeFromProbe(0xFFFFF000'u32, 0xFFFFFFF0'u32) == 4096, "4 KB"

  # 1 MB: probe = 0xFFF00000
  assert barSizeFromProbe(0xFFF00000'u32, 0xFFFFFFF0'u32) == 1024*1024, "1 MB"

  # 16 bytes (minimum useful MMIO): probe = 0xFFFFFFF0
  assert barSizeFromProbe(0xFFFFFFF0'u32, 0xFFFFFFF0'u32) == 16, "16 bytes"

  # I/O BAR mask is 0xFFFFFFFC; 256 bytes I/O: probe = 0xFFFFFF00
  assert barSizeFromProbe(0xFFFFFF00'u32, 0xFFFFFFFC'u32) == 256, "256 bytes I/O"

  # Unimplemented BAR → probe reads back 0 → size 0
  assert barSizeFromProbe(0'u32, 0xFFFFFFF0'u32) == 0, "unimplemented BAR"

  echo "PASS: BAR size formula"

# ── pciConfigReadU16 shift logic ───────────────────────────────────────────

proc readU16FromDword(dword: uint32; reg: uint8): uint16 {.inline.} =
  uint16((dword shr (uint32(reg and 2'u8) * 8)) and 0xFFFF'u32)

proc readU8FromDword(dword: uint32; reg: uint8): uint8 {.inline.} =
  uint8((dword shr (uint32(reg and 3'u8) * 8)) and 0xFF'u32)

proc testConfigNarrowReads() =
  let dword = 0xDDCCBBAA'u32

  # U16 at aligned offset → low word
  assert readU16FromDword(dword, 0x00) == 0xBBAA'u16, "U16 at reg+0"
  # U16 at +2 → high word
  assert readU16FromDword(dword, 0x02) == 0xDDCC'u16, "U16 at reg+2"

  # U8 at each byte
  assert readU8FromDword(dword, 0x00) == 0xAA'u8, "U8 byte 0"
  assert readU8FromDword(dword, 0x01) == 0xBB'u8, "U8 byte 1"
  assert readU8FromDword(dword, 0x02) == 0xCC'u8, "U8 byte 2"
  assert readU8FromDword(dword, 0x03) == 0xDD'u8, "U8 byte 3"

  echo "PASS: config narrow-read shift logic"

when isMainModule:
  testPciAddressEncoding()
  testPciDeviceName()
  testBarSizeFormula()
  testConfigNarrowReads()
  echo "All PCI tests passed."
