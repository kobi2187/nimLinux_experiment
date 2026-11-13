# SPDX-License-Identifier: GPL-2.0
## PCI Device Enumeration and Name Table.
##
## pciScan() walks all 256 buses × 32 slots × 8 functions.
## Present devices (vendorId != 0xFFFF) are stored in gPciDevices[].
## Single-function devices skip functions 1-7 (bit 7 of headerType clear).

import pci_config

const
  MaxPciDevices* = 64
  PciVendorNone  = 0xFFFF'u16

type
  PciDevice* = object
    found*:     bool
    bus*, slot*, fn*:     uint8
    vendorId*, deviceId*: uint16
    classCode*: uint8
    subclass*:  uint8
    progIf*:    uint8
    headerType*: uint8

var
  gPciDevices*: array[MaxPciDevices, PciDevice]
  gPciCount*:   int

proc pciReadDevice(bus, slot, fn: uint8): PciDevice =
  result.found    = true
  result.bus      = bus
  result.slot     = slot
  result.fn       = fn
  result.vendorId = pciConfigReadU16(bus, slot, fn, 0x00)
  result.deviceId = pciConfigReadU16(bus, slot, fn, 0x02)
  let classReg    = pciConfigReadU32(bus, slot, fn, 0x08)
  result.classCode  = uint8((classReg shr 24) and 0xFF'u32)
  result.subclass   = uint8((classReg shr 16) and 0xFF'u32)
  result.progIf     = uint8((classReg shr  8) and 0xFF'u32)
  result.headerType = pciConfigReadU8(bus, slot, fn, 0x0E)

proc pciScanSlot(bus, slot: uint8) =
  let dev0 = pciReadDevice(bus, slot, 0)
  if dev0.vendorId == PciVendorNone:
    return
  if gPciCount < MaxPciDevices:
    gPciDevices[gPciCount] = dev0
    inc gPciCount

  # Multi-function device — bit 7 of headerType set
  if (dev0.headerType and 0x80'u8) == 0:
    return
  for fn in 1'u8..7'u8:
    let dev = pciReadDevice(bus, slot, fn)
    if dev.vendorId != PciVendorNone and gPciCount < MaxPciDevices:
      gPciDevices[gPciCount] = dev
      inc gPciCount

proc pciScan*() =
  ## Enumerate all PCI devices and populate gPciDevices[0..<gPciCount].
  gPciCount = 0
  for bus in 0'u8..255'u8:
    for slot in 0'u8..31'u8:
      pciScanSlot(bus, slot)

type VendorDevice = object
  vendor, device: uint16
  name: cstring

const KnownDevices: array[10, VendorDevice] = [
  VendorDevice(vendor: 0x1AF4, device: 0x1000, name: "virtio-net"),
  VendorDevice(vendor: 0x1AF4, device: 0x1001, name: "virtio-block"),
  VendorDevice(vendor: 0x1AF4, device: 0x1050, name: "virtio-gpu"),
  VendorDevice(vendor: 0x1AF4, device: 0x1052, name: "virtio-input"),
  VendorDevice(vendor: 0x8086, device: 0x100E, name: "e1000 (Intel 82540EM)"),
  VendorDevice(vendor: 0x8086, device: 0x1237, name: "Intel 440FX host bridge"),
  VendorDevice(vendor: 0x8086, device: 0x7000, name: "Intel PIIX3 ISA bridge"),
  VendorDevice(vendor: 0x8086, device: 0x7010, name: "Intel PIIX3 IDE"),
  VendorDevice(vendor: 0x8086, device: 0x7113, name: "Intel PIIX4 ACPI"),
  VendorDevice(vendor: 0x1234, device: 0x1111, name: "QEMU VGA"),
]

proc pciDeviceName*(vendor, device: uint16): cstring =
  ## Return a human-readable name for a vendor:device pair, or nil if unknown.
  for entry in KnownDevices:
    if entry.vendor == vendor and entry.device == device:
      return entry.name
  nil

proc pciVirtioFindNth*(vendorId, deviceId: uint16; n: int): PciDevice =
  ## The n-th (0-based, in scan order) device matching vendorId:deviceId.
  ## Returns a device with found=false if there are fewer than n+1.
  var seen = 0
  for i in 0..<gPciCount:
    let d = gPciDevices[i]
    if d.vendorId == vendorId and d.deviceId == deviceId:
      if seen == n: return d
      inc seen
  PciDevice(found: false, bus: 0, slot: 0, fn: 0, vendorId: 0xFFFF'u16)

proc pciVirtioFind*(vendorId, deviceId: uint16): PciDevice =
  ## Find the first (bus, slot, fn) matching vendorId:deviceId.
  ## Returns a device with found=false if not found.
  pciVirtioFindNth(vendorId, deviceId, 0)
