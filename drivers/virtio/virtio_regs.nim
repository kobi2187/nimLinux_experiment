# SPDX-License-Identifier: GPL-2.0
## Virtio MMIO register layout and PCI device search.
##
## Virtio legacy MMIO: device exposes a flat register window via BAR0.
## All registers are 32-bit; 64-bit values use two consecutive 32-bit slots.

import ../pci/pci_device

const
  VirtioMagic*        = 0x74726976'u32   # "virt" in little-endian
  VirtioStatusAck*    = 1'u32
  VirtioStatusDriver* = 2'u32
  VirtioStatusFeatOk* = 8'u32
  VirtioStatusOk*     = 4'u32
  VirtioStatusFailed* = 128'u32

  # Feature bits for virtio-net
  VirtioNetFMac*      = 1'u32 shl 5

  # Register offsets (bytes from MMIO base)
  VirtioRegMagic*          = 0x00'u32
  VirtioRegVersion*        = 0x04'u32
  VirtioRegDeviceId*       = 0x08'u32
  VirtioRegVendorId*       = 0x0C'u32
  VirtioRegDeviceFeatures* = 0x10'u32
  VirtioRegDeviceFeatSel*  = 0x14'u32
  VirtioRegDriverFeatures* = 0x20'u32
  VirtioRegDriverFeatSel*  = 0x24'u32
  VirtioRegQueueSel*       = 0x30'u32
  VirtioRegQueueNumMax*    = 0x34'u32
  VirtioRegQueueNum*       = 0x38'u32
  VirtioRegQueueReady*     = 0x44'u32
  VirtioRegQueueNotify*    = 0x50'u32
  VirtioRegInterruptStatus* = 0x60'u32
  VirtioRegInterruptAck*   = 0x64'u32
  VirtioRegStatus*         = 0x70'u32
  VirtioRegQueueDescLo*    = 0x80'u32
  VirtioRegQueueDescHi*    = 0x84'u32
  VirtioRegQueueDriverLo*  = 0x90'u32
  VirtioRegQueueDriverHi*  = 0x94'u32
  VirtioRegQueueDeviceLo*  = 0xA0'u32
  VirtioRegQueueDeviceHi*  = 0xA4'u32
  VirtioRegConfigGen*      = 0xFC'u32
  VirtioRegConfig*         = 0x100'u32

proc mmioRead32*(base: uint64; offset: uint32): uint32 {.inline.} =
  cast[ptr uint32](base + uint64(offset))[]

proc mmioWrite32*(base: uint64; offset: uint32; val: uint32) {.inline.} =
  cast[ptr uint32](base + uint64(offset))[] = val

proc mmioRead8*(base: uint64; offset: uint32): uint8 {.inline.} =
  cast[ptr uint8](base + uint64(offset))[]

proc pciVirtioFind*(vendorId, deviceId: uint16): tuple[found: bool; bus, slot, fn: uint8] =
  ## Search gPciDevices[] for a matching vendor:device pair.
  for i in 0..<gPciCount:
    let d = gPciDevices[i]
    if d.vendorId == vendorId and d.deviceId == deviceId:
      return (true, d.bus, d.slot, d.fn)
  (false, 0'u8, 0'u8, 0'u8)
