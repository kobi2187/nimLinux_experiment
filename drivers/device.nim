# SPDX-License-Identifier: GPL-2.0
## Device Driver Framework
##
## Abstraction for hardware devices and driver interface
## Supports character and block devices

import ../core/types

type
  # ═══════════════════════════════════════════════════════════════════════════
  # Device Types
  # ═══════════════════════════════════════════════════════════════════════════

  DeviceType* = enum
    ## Device classification
    dtCharacter = 0                ## Character device (unbuffered)
    dtBlock = 1                    ## Block device (buffered)
    dtNetwork = 2                  ## Network device
    dtMisc = 3                     ## Miscellaneous device

  DeviceState* = enum
    ## Device state
    dsProbing = 0
    dsInitialized = 1
    dsRunning = 2
    dsSuspended = 3
    dsError = 4
    dsRemoved = 5

  DeviceBusType* = enum
    ## Device bus/attachment type
    dbtPci = 0
    dbtUsb = 1
    dbtAcpi = 2
    dbtPlatform = 3
    dbtIsa = 4

  Device* = object
    ## Generic device object
    deviceId*: uint32
    busType*: DeviceBusType
    deviceType*: DeviceType
    state*: DeviceState
    irq*: uint8
    dmaChanCount*: uint8
    vendorName*: array[64, uint8]
    deviceName*: array[64, uint8]

  CharacterDeviceOps* = object
    ## Character device operations
    open*: proc(dev: ptr Device, flags: uint16): int32
    close*: proc(dev: ptr Device): int32
    read*: proc(dev: ptr Device, buffer: pointer, count: uint64): int64
    write*: proc(dev: ptr Device, buffer: pointer, count: uint64): int64
    ioctl*: proc(dev: ptr Device, cmd: uint32, arg: pointer): int32

  BlockDeviceOps* = object
    ## Block device operations
    open*: proc(dev: ptr Device, flags: uint16): int32
    close*: proc(dev: ptr Device): int32
    readBlock*: proc(dev: ptr Device, blockNum: uint64, buffer: pointer): int32
    writeBlock*: proc(dev: ptr Device, blockNum: uint64, buffer: pointer): int32
    ioctl*: proc(dev: ptr Device, cmd: uint32, arg: pointer): int32
    getCapacity*: proc(dev: ptr Device): uint64

  NetworkDeviceOps* = object
    ## Network device operations
    open*: proc(dev: ptr Device): int32
    close*: proc(dev: ptr Device): int32
    transmit*: proc(dev: ptr Device, packet: pointer, length: uint16): int32
    receive*: proc(dev: ptr Device): pointer
    getStats*: proc(dev: ptr Device): pointer

  DriverModule* = object
    ## Driver module interface
    name*: array[64, uint8]
    version*: array[16, uint8]
    probe*: proc(dev: ptr Device): bool
    init*: proc(dev: ptr Device): int32
    shutdown*: proc(dev: ptr Device): int32
    suspend*: proc(dev: ptr Device): int32
    resume*: proc(dev: ptr Device): int32

  InterruptHandler* = proc(irq: uint8, device: ptr Device) {.cdecl.}

# ═══════════════════════════════════════════════════════════════════════════
# Device Manager Constants
# ═══════════════════════════════════════════════════════════════════════════

const
  MaxDevices* = 512
  MaxCharDevices* = 256
  MaxBlockDevices* = 256
  MaxNetDevices* = 64
  MaxDrivers* = 128
  MaxInterruptHandlers* = 256

# ═══════════════════════════════════════════════════════════════════════════
# Global Device State
# ═══════════════════════════════════════════════════════════════════════════

var
  gDeviceTable*: array[MaxDevices, Device]
  gCharDeviceOps*: array[MaxCharDevices, CharacterDeviceOps]
  gBlockDeviceOps*: array[MaxBlockDevices, BlockDeviceOps]
  gNetDeviceOps*: array[MaxNetDevices, NetworkDeviceOps]
  gDriverModules*: array[MaxDrivers, DriverModule]
  gInterruptHandlers*: array[MaxInterruptHandlers, InterruptHandler]
  gNextDeviceId*: uint32 = 1
  gDeviceCount*: uint32 = 0

# ═══════════════════════════════════════════════════════════════════════════
# Device Registration
# ═══════════════════════════════════════════════════════════════════════════

proc registerDevice*(busType: DeviceBusType, deviceType: DeviceType,
                     vendorName: cstring, deviceName: cstring): uint32 =
  ## Register a new device
  ## Returns device ID or 0 on failure
  if gDeviceCount >= MaxDevices:
    return 0

  var device: Device
  device.deviceId = gNextDeviceId
  inc gNextDeviceId
  device.busType = busType
  device.deviceType = deviceType
  device.state = dsProbing
  # TODO: Copy vendorName and deviceName into fixed-size arrays with null termination
  inc gDeviceCount
  return device.deviceId

proc tryRegisterDevice*(busType: DeviceBusType, deviceType: DeviceType,
                        vendorName: cstring, deviceName: cstring): Result[uint32, KernelError] =
  ## Register a new device with Result-based error handling
  if gDeviceCount >= MaxDevices:
    return err[uint32, KernelError](keOutOfMemory)
  let deviceId = registerDevice(busType, deviceType, vendorName, deviceName)
  if deviceId == 0:
    return err[uint32, KernelError](keAlreadyExists)
  return ok[uint32, KernelError](deviceId)

proc getDevice*(deviceId: uint32): ptr Device =
  ## Get device by ID (returns nil if not found)
  for i in 0..<MaxDevices:
    if gDeviceTable[i].deviceId == deviceId:
      return addr gDeviceTable[i]
  return nil

proc tryGetDevice*(deviceId: uint32): Option[ptr Device] =
  ## Get device by ID with Option-based safety
  for i in 0..<MaxDevices:
    if gDeviceTable[i].deviceId == deviceId:
      return some(addr gDeviceTable[i])
  return none(ptr Device)

proc setDeviceState*(deviceId: uint32, state: DeviceState) =
  ## Change device state
  let dev = getDevice(deviceId)
  if dev != nil:
    dev.state = state

# ═══════════════════════════════════════════════════════════════════════════
# Character Device Operations
# ═══════════════════════════════════════════════════════════════════════════

proc registerCharDeviceOps*(major: uint32, ops: CharacterDeviceOps) =
  ## Register character device operations
  if major < MaxCharDevices:
    gCharDeviceOps[major] = ops

proc getCharDeviceOps*(major: uint32): ptr CharacterDeviceOps =
  ## Get character device operations
  if major < MaxCharDevices:
    return addr gCharDeviceOps[major]
  return nil

proc charDeviceOpen*(deviceId: uint32, flags: uint16): int32 =
  ## Open character device
  let dev = getDevice(deviceId)
  if dev != nil and dev.deviceType == dtCharacter:
    let ops = getCharDeviceOps(deviceId)
    if ops != nil and ops.open != nil:
      return ops.open(dev, flags)
  return -1

proc charDeviceRead*(deviceId: uint32, buffer: pointer, count: uint64): int64 =
  ## Read from character device
  let dev = getDevice(deviceId)
  if dev != nil and dev.deviceType == dtCharacter:
    let ops = getCharDeviceOps(deviceId)
    if ops != nil and ops.read != nil:
      return ops.read(dev, buffer, count)
  return -1

proc charDeviceWrite*(deviceId: uint32, buffer: pointer, count: uint64): int64 =
  ## Write to character device
  let dev = getDevice(deviceId)
  if dev != nil and dev.deviceType == dtCharacter:
    let ops = getCharDeviceOps(deviceId)
    if ops != nil and ops.write != nil:
      return ops.write(dev, buffer, count)
  return -1

# ═══════════════════════════════════════════════════════════════════════════
# Block Device Operations
# ═══════════════════════════════════════════════════════════════════════════

proc registerBlockDeviceOps*(major: uint32, ops: BlockDeviceOps) =
  ## Register block device operations
  if major < MaxBlockDevices:
    gBlockDeviceOps[major] = ops

proc blockDeviceReadBlock*(deviceId: uint32, blockNum: uint64, buffer: pointer): int32 =
  ## Read block from device
  let dev = getDevice(deviceId)
  if dev != nil and dev.deviceType == dtBlock:
    let ops = addr gBlockDeviceOps[0]  # Simplified lookup
    if ops != nil and ops.readBlock != nil:
      return ops.readBlock(dev, blockNum, buffer)
  return -1

proc blockDeviceWriteBlock*(deviceId: uint32, blockNum: uint64, buffer: pointer): int32 =
  ## Write block to device
  let dev = getDevice(deviceId)
  if dev != nil and dev.deviceType == dtBlock:
    let ops = addr gBlockDeviceOps[0]
    if ops != nil and ops.writeBlock != nil:
      return ops.writeBlock(dev, blockNum, buffer)
  return -1

proc blockDeviceGetCapacity*(deviceId: uint32): uint64 =
  ## Get device capacity in bytes
  let dev = getDevice(deviceId)
  if dev != nil and dev.deviceType == dtBlock:
    let ops = addr gBlockDeviceOps[0]
    if ops != nil and ops.getCapacity != nil:
      return ops.getCapacity(dev)
  return 0

# ═══════════════════════════════════════════════════════════════════════════
# Interrupt Handling
# ═══════════════════════════════════════════════════════════════════════════

proc registerInterruptHandler*(irq: uint8, handler: InterruptHandler) =
  ## Register interrupt handler for IRQ
  if irq < MaxInterruptHandlers:
    gInterruptHandlers[irq] = handler

proc handleDeviceInterrupt*(irq: uint8, device: ptr Device) =
  ## Handle interrupt from device
  if irq < MaxInterruptHandlers and gInterruptHandlers[irq] != nil:
    gInterruptHandlers[irq](irq, device)

# ═══════════════════════════════════════════════════════════════════════════
# Driver Module Management
# ═══════════════════════════════════════════════════════════════════════════

proc registerDriverModule*(module: DriverModule): uint32 =
  ## Register driver module
  for i in 0..<MaxDrivers:
    if gDriverModules[i].name[0] == 0:
      gDriverModules[i] = module
      return uint32(i)
  return 0

proc initializeDriver*(driverId: uint32, device: ptr Device): bool =
  ## Initialize driver for device
  if driverId < MaxDrivers:
    let driver = addr gDriverModules[driverId]
    if driver.init != nil:
      return driver.init(device) == 0
  return false

# ═══════════════════════════════════════════════════════════════════════════
# Device Discovery and Probing
# ═══════════════════════════════════════════════════════════════════════════

proc probeDevice*(device: ptr Device): bool =
  ## Probe device to find matching driver
  for i in 0..<MaxDrivers:
    let driver = addr gDriverModules[i]
    if driver.probe != nil and driver.probe(device):
      return initializeDriver(uint32(i), device)
  return false

proc getDevicesByBusType*(busType: DeviceBusType): seq[uint32] =
  ## Get all devices on a specific bus
  # Strategy: Iterate device table, collect matching bus type
  var devices: seq[uint32] = @[]
  for i in 0..<MaxDevices:
    if gDeviceTable[i].busType == busType and gDeviceTable[i].deviceId > 0:
      devices.add(gDeviceTable[i].deviceId)
  return devices

proc getDevicesByType*(deviceType: DeviceType): seq[uint32] =
  ## Get all devices of specific type
  # Strategy: Iterate device table, collect matching device type
  var devices: seq[uint32] = @[]
  for i in 0..<MaxDevices:
    if gDeviceTable[i].deviceType == deviceType and gDeviceTable[i].deviceId > 0:
      devices.add(gDeviceTable[i].deviceId)
  return devices

var gBusDevicesScanned*: array[5, bool]  # Track which buses have been scanned

proc enumerateDevices*(busType: DeviceBusType) =
  ## Enumerate devices on bus
  # Strategy: Scan bus (PCI, USB, etc) and create device objects
  # This would call bus-specific enumeration (e.g., pciEnumerateAll)
  case busType
  of dbtPci:
    # TODO: Iterate PCI bus using config space (bus 0-255, device 0-31, function 0-7)
    # TODO: Check vendor ID for valid devices (0xFFFF means not present)
    # TODO: For each device, call registerDevice() and then probe drivers
    gBusDevicesScanned[ord(dbtPci)] = true
  of dbtUsb:
    # TODO: Scan USB controllers (UHCI, OHCI, EHCI, xHCI)
    # TODO: Enumerate ports and connected devices
    # TODO: Parse device descriptors and call registerDevice()
    gBusDevicesScanned[ord(dbtUsb)] = true
  of dbtAcpi:
    # TODO: Walk ACPI namespace tree from root (_SB_)
    # TODO: Evaluate _HID and _UID to identify devices
    # TODO: Call registerDevice() for each device object found
    gBusDevicesScanned[ord(dbtAcpi)] = true
  of dbtPlatform:
    # TODO: Iterate platform device registry (from bootloader or hardcoded)
    # TODO: Create device entries for each platform device
    gBusDevicesScanned[ord(dbtPlatform)] = true
  of dbtIsa:
    # TODO: Scan ISA address ranges for known device signatures
    # TODO: Probe for legacy devices (COM ports, LPT, floppy)
    gBusDevicesScanned[ord(dbtIsa)] = true

proc scanAllBuses*() =
  ## Scan all device buses
  # Strategy: Enumerate devices from all bus types
  for bus in [dbtPci, dbtUsb, dbtAcpi, dbtPlatform, dbtIsa]:
    enumerateDevices(bus)

# ═══════════════════════════════════════════════════════════════════════════
# Device Statistics
# ═══════════════════════════════════════════════════════════════════════════

proc getDeviceCount*(): uint32 =
  ## Get total number of registered devices
  return gDeviceCount

proc getDeviceInfo*(deviceId: uint32): string =
  ## Get formatted device information
  let dev = getDevice(deviceId)
  if dev == nil:
    return "Device not found"
  "ID: " & $dev.deviceId & " Bus: " & $dev.busType & " State: " & $dev.state

# ═══════════════════════════════════════════════════════════════════════════
# Device Manager Initialization
# ═══════════════════════════════════════════════════════════════════════════

proc initDeviceManager*() =
  ## Initialize device management system
  gDeviceCount = 0
  gNextDeviceId = 1

proc countDevicesByState*(state: DeviceState): uint32 =
  ## Count devices in specific state
  # Strategy: Iterate and count
  var count = 0'u32
  for i in 0..<MaxDevices:
    if gDeviceTable[i].state == state and gDeviceTable[i].deviceId > 0:
      inc count
  return count

proc listAllDevices*(): string =
  ## List all registered devices
  # Strategy: Format device information
  var result = "Registered Devices:\n"
  for i in 0..<gDeviceCount:
    let dev = addr gDeviceTable[i]
    if dev.deviceId > 0:
      result = result & "  Device " & $dev.deviceId & ": Bus=" &
               $dev.busType & " Type=" & $dev.deviceType &
               " State=" & $dev.state & "\n"
  return result

proc deviceStats*(): string =
  ## Return formatted device statistics
  # Strategy: Count devices by state and type
  let running = countDevicesByState(dsRunning)
  let suspended = countDevicesByState(dsSuspended)
  let errors = countDevicesByState(dsError)

  return "Devices: " & $gDeviceCount & "/" & $MaxDevices &
         " (Running: " & $running & " Suspended: " & $suspended &
         " Errors: " & $errors & ")"

proc getDevicesByScan*(busType: DeviceBusType): bool =
  ## Check if bus has been scanned
  # Strategy: Check scan status
  return gBusDevicesScanned[ord(busType)]
