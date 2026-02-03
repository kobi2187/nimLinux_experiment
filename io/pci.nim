# SPDX-License-Identifier: GPL-2.0
## PCI Bus Enumeration and Device Discovery
##
## Provides PCI configuration access and device enumeration
## for finding and configuring hardware devices

import ../core/types

type
  # ═══════════════════════════════════════════════════════════════════════════
  # PCI Configuration
  # ═══════════════════════════════════════════════════════════════════════════

  PciVendorId* = distinct uint16
  PciDeviceId* = distinct uint16
  PciBusId* = distinct uint8
  PciSlot* = distinct uint8
  PciFunction* = distinct uint8

  PciAddress* = object
    ## PCI device address (bus:slot.function)
    bus*: PciBusId
    slot*: PciSlot
    function*: PciFunction

  PciHeaderType* = enum
    ## PCI header type
    phtGeneral = 0x00      ## Standard device
    phtBridge = 0x01       ## PCI-to-PCI bridge
    phtCardbus = 0x02      ## CardBus bridge

  PciClass* = enum
    ## PCI device class
    pcUnclassified = 0x00
    pcMassStorage = 0x01
    pcNetworkCtrl = 0x02
    pcDisplay = 0x03
    pcMultimedia = 0x04
    pcMemory = 0x05
    pcBridge = 0x06
    pcSimple = 0x07
    pcBase = 0x08
    pcInput = 0x09
    pcDocking = 0x0A
    pcProcessor = 0x0B
    pcSerial = 0x0C
    pcWireless = 0x0D
    pcIntelligent = 0x0E
    pcSatellite = 0x0F
    pcEncryption = 0x10
    pcDataAcq = 0x11
    pcOther = 0xFF

  PciDeviceInfo* = object
    ## Discovered PCI device information
    address*: PciAddress
    vendorId*: PciVendorId
    deviceId*: PciDeviceId
    classCode*: PciClass
    subclass*: uint8
    progIf*: uint8
    headerType*: PciHeaderType
    bars*: array[6, uint64]           ## Base Address Registers
    irqLine*: uint8
    irqPin*: uint8

  PciEnumerationError* = enum
    pceSuccess
    pceNoDevice
    pceInvalidAddress
    pceEnumerationFailed

  PciEnumerator* = object
    ## PCI bus enumerator state
    devices*: array[256, array[32, array[8, PciDeviceInfo]]]  ## bus/slot/function
    deviceCount*: uint32
    initialized*: bool

# ═══════════════════════════════════════════════════════════════════════════
# PCI Configuration Access (Intel 82093AA compatible)
# ═══════════════════════════════════════════════════════════════════════════

const
  PciConfigAddress = 0xCF8'u32
  PciConfigData = 0xCFC'u32

proc pciReadConfigByte*(address: PciAddress, offset: uint8): uint8 =
  ## Read single byte from PCI config space
  let configAddr = (uint32(address.bus) shl 16) or
                   (uint32(address.slot) shl 11) or
                   (uint32(address.function) shl 8) or
                   uint32(offset and 0xFC) or
                   0x80000000'u32
  # Would use outl/inl assembly here
  0'u8

proc pciReadConfigWord*(address: PciAddress, offset: uint8): uint16 =
  ## Read 16-bit word from PCI config space
  0'u16

proc pciReadConfigDword*(address: PciAddress, offset: uint8): uint32 =
  ## Read 32-bit dword from PCI config space
  0'u32

proc pciWriteConfigByte*(address: PciAddress, offset: uint8, value: uint8) =
  ## Write single byte to PCI config space
  discard

proc pciWriteConfigWord*(address: PciAddress, offset: uint8, value: uint16) =
  ## Write 16-bit word to PCI config space
  discard

proc pciWriteConfigDword*(address: PciAddress, offset: uint8, value: uint32) =
  ## Write 32-bit dword to PCI config space
  discard

# ═══════════════════════════════════════════════════════════════════════════
# PCI Device Detection
# ═══════════════════════════════════════════════════════════════════════════

proc pciDeviceExists*(address: PciAddress): bool =
  ## Check if PCI device exists at address
  let vendorId = pciReadConfigWord(address, 0)
  vendorId != 0xFFFF'u16

proc pciReadDeviceInfo*(address: PciAddress): PciDeviceInfo =
  ## Read complete device information from PCI config
  result.address = address
  result.vendorId = PciVendorId(pciReadConfigWord(address, 0x00))
  result.deviceId = PciDeviceId(pciReadConfigWord(address, 0x02))
  let classReg = pciReadConfigDword(address, 0x08)
  result.classCode = PciClass(classReg shr 24)
  result.subclass = uint8((classReg shr 16) and 0xFF)
  result.progIf = uint8((classReg shr 8) and 0xFF)
  result.headerType = PciHeaderType(pciReadConfigByte(address, 0x0E) and 0x7F)
  result.irqLine = pciReadConfigByte(address, 0x3C)
  result.irqPin = pciReadConfigByte(address, 0x3D)

  # Read BARs
  for i in 0..<6:
    let barOffset = uint8(0x10 + (i * 4))
    result.bars[i] = uint64(pciReadConfigDword(address, barOffset))

proc pciEnumerateAll*(enumerator: var PciEnumerator) =
  ## Enumerate all PCI devices on all buses
  enumerator.deviceCount = 0
  enumerator.initialized = true

  for bus in 0'u8..255'u8:
    for slot in 0'u8..31'u8:
      for function in 0'u8..7'u8:
        let address = PciAddress(
          bus: PciBusId(bus),
          slot: PciSlot(slot),
          function: PciFunction(function)
        )

        if pciDeviceExists(address):
          let deviceInfo = pciReadDeviceInfo(address)
          if enumerator.deviceCount < 256 * 32 * 8:
            inc enumerator.deviceCount

proc pciGetDevicesByClass*(enumerator: PciEnumerator, classCode: PciClass): seq[PciDeviceInfo] =
  ## Find all devices of a specific class
  result = @[]
  # Would iterate through enumerator.devices and filter

proc pciGetDevicesByVendor*(enumerator: PciEnumerator, vendorId: PciVendorId): seq[PciDeviceInfo] =
  ## Find all devices from a specific vendor
  result = @[]

# ═══════════════════════════════════════════════════════════════════════════
# Bridge Support
# ═══════════════════════════════════════════════════════════════════════════

type
  PciBridgeInfo* = object
    ## PCI-to-PCI bridge information
    primaryBus*: uint8
    secondaryBus*: uint8
    subordinateBus*: uint8
    secondaryLatency*: uint8

proc pciGetBridgeInfo*(address: PciAddress): PciBridgeInfo =
  ## Read bridge configuration
  result.primaryBus = pciReadConfigByte(address, 0x18)
  result.secondaryBus = pciReadConfigByte(address, 0x19)
  result.subordinateBus = pciReadConfigByte(address, 0x1A)

proc pciEnumerateBus*(enumerator: var PciEnumerator, bus: uint8) =
  ## Enumerate devices on a specific bus, following bridges
  discard
