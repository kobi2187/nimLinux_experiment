# SPDX-License-Identifier: GPL-2.0
## PCI Configuration Space Access — port I/O mechanism (Type 1).
##
## The host bridge exposes two 32-bit ports:
##   0xCF8  CONFIG_ADDRESS — selects bus/slot/fn/register
##   0xCFC  CONFIG_DATA    — transfers the dword at that register
##
## All reads/writes go through this pair; narrower widths are extracted
## by shifting and masking the surrounding dword.

import ../../arch/x86_64/cpu_primitives

const
  PciAddressPort* = 0xCF8'u16
  PciDataPort*    = 0xCFC'u16

proc pciAddress(bus, slot, fn, reg: uint8): uint32 {.inline.} =
  ## Assemble the CONFIG_ADDRESS dword.
  ## Bit 31 = enable bit; reg is dword-aligned (bottom 2 bits forced 0).
  (1'u32 shl 31) or
  (uint32(bus)  shl 16) or
  (uint32(slot) shl 11) or
  (uint32(fn)   shl  8) or
  uint32(reg and 0xFC'u8)

proc pciConfigReadU32*(bus, slot, fn, reg: uint8): uint32 =
  ## Read a 32-bit dword from PCI config space.
  outl(PciAddressPort, pciAddress(bus, slot, fn, reg))
  inl(PciDataPort)

proc pciConfigReadU16*(bus, slot, fn, reg: uint8): uint16 =
  ## Read a 16-bit word; shifts the surrounding dword by (reg & 2) * 8.
  let dword = pciConfigReadU32(bus, slot, fn, reg)
  uint16((dword shr (uint32(reg and 2'u8) * 8)) and 0xFFFF'u32)

proc pciConfigReadU8*(bus, slot, fn, reg: uint8): uint8 =
  ## Read a byte; shifts the surrounding dword by (reg & 3) * 8.
  let dword = pciConfigReadU32(bus, slot, fn, reg)
  uint8((dword shr (uint32(reg and 3'u8) * 8)) and 0xFF'u32)

proc pciConfigWriteU32*(bus, slot, fn, reg: uint8, val: uint32) =
  ## Write a 32-bit dword to PCI config space.
  outl(PciAddressPort, pciAddress(bus, slot, fn, reg))
  outl(PciDataPort, val)

proc pciConfigWriteU16*(bus, slot, fn, reg: uint8, val: uint16) =
  ## Read-modify-write a 16-bit word within its dword.
  let shift = uint32(reg and 2'u8) * 8
  let mask  = 0xFFFF'u32 shl shift
  let orig  = pciConfigReadU32(bus, slot, fn, reg)
  let next  = (orig and not mask) or (uint32(val) shl shift)
  pciConfigWriteU32(bus, slot, fn, reg, next)

const PciCommandIntxDisable* = 1'u16 shl 10

proc pciDisableIntx*(bus, slot, fn: uint8) =
  ## Stop a polled device from asserting its INTx line. PCI INTx lines are
  ## shared; an asserted line nobody acknowledges blocks every other device on it.
  let cmd = pciConfigReadU16(bus, slot, fn, 0x04'u8)
  pciConfigWriteU16(bus, slot, fn, 0x04'u8, cmd or PciCommandIntxDisable)
