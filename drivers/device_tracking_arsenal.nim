# SPDX-License-Identifier: GPL-2.0
## Device Tracking with Arsenal Roaring Bitmaps
##
## High-performance device registry and tracking using compressed bitmaps
## for efficient state queries and iterative operations. Optimized for
## systems with hundreds of devices and complex enumeration patterns.

import ../core/types
import ../kern/arsenal_adapters

type
  # ═══════════════════════════════════════════════════════════════════════════
  # Device Set Tracking
  # ═══════════════════════════════════════════════════════════════════════════

  DeviceRegistry* = object
    ## Compressed registry of all active devices
    ## Uses roaring bitmaps for O(1) containment and fast iteration
    allDevices*: DeviceSet

  DeviceStateTracker* = object
    ## Track devices by state (running, suspended, error, etc)
    ## Each state has its own compressed set
    probing*: DeviceSet
    initialized*: DeviceSet
    running*: DeviceSet
    suspended*: DeviceSet
    error*: DeviceSet
    removed*: DeviceSet

  BusDeviceTracker* = object
    ## Track devices by bus type for efficient enumeration
    pciDevices*: DeviceSet
    usbDevices*: DeviceSet
    acpiDevices*: DeviceSet
    platformDevices*: DeviceSet
    isaDevices*: DeviceSet

  DeviceTypeTracker* = object
    ## Track devices by type for categorization
    charDevices*: DeviceSet
    blockDevices*: DeviceSet
    networkDevices*: DeviceSet
    miscDevices*: DeviceSet

  InterruptMapping* = object
    ## Efficient IRQ to device mapping
    ## Multiple devices can share an IRQ
    irqDevices*: array[256, DeviceSet]

# ═══════════════════════════════════════════════════════════════════════════
# Device Registry Operations
# ═══════════════════════════════════════════════════════════════════════════

proc initDeviceRegistry*(): DeviceRegistry =
  ## Initialize empty device registry
  result.allDevices = initDeviceSet()

proc registerDeviceArsenal*(registry: var DeviceRegistry, deviceId: uint32) =
  ## Register device in global registry
  # Strategy: Add to compressed set (O(1) amortized with bitmap encoding)
  addDevice(registry.allDevices, deviceId)

proc unregisterDeviceArsenal*(registry: var DeviceRegistry, deviceId: uint32) =
  ## Unregister device from global registry
  removeDevice(registry.allDevices, deviceId)

proc hasDeviceArsenal*(registry: DeviceRegistry, deviceId: uint32): bool =
  ## Check if device exists in registry
  # Strategy: Roaring bitmap lookup (O(log n) worst case, O(1) average)
  return hasDevice(registry.allDevices, deviceId)

proc deviceCountArsenal*(registry: DeviceRegistry): uint32 =
  ## Get total number of registered devices
  # Strategy: Efficient cardinality query from roaring bitmap
  return deviceCount(registry.allDevices)

# ═══════════════════════════════════════════════════════════════════════════
# Device State Tracking
# ═══════════════════════════════════════════════════════════════════════════

proc initDeviceStateTracker*(): DeviceStateTracker =
  ## Initialize empty state tracker
  result.probing = initDeviceSet()
  result.initialized = initDeviceSet()
  result.running = initDeviceSet()
  result.suspended = initDeviceSet()
  result.error = initDeviceSet()
  result.removed = initDeviceSet()

proc updateDeviceState*(tracker: var DeviceStateTracker, deviceId: uint32, oldState: uint32, newState: uint32) =
  ## Update device state (removes from old, adds to new)
  # Strategy: Remove from old state set, add to new state set
  # Each set is independent, allowing fast state queries
  case oldState
  of 0: removeDevice(tracker.probing, deviceId)
  of 1: removeDevice(tracker.initialized, deviceId)
  of 2: removeDevice(tracker.running, deviceId)
  of 3: removeDevice(tracker.suspended, deviceId)
  of 4: removeDevice(tracker.error, deviceId)
  of 5: removeDevice(tracker.removed, deviceId)
  else: discard

  case newState
  of 0: addDevice(tracker.probing, deviceId)
  of 1: addDevice(tracker.initialized, deviceId)
  of 2: addDevice(tracker.running, deviceId)
  of 3: addDevice(tracker.suspended, deviceId)
  of 4: addDevice(tracker.error, deviceId)
  of 5: addDevice(tracker.removed, deviceId)
  else: discard

proc countDevicesInState*(tracker: DeviceStateTracker, state: uint32): uint32 =
  ## Get count of devices in specific state
  # Strategy: Direct cardinality lookup from appropriate roaring bitmap
  case state
  of 0: return deviceCount(tracker.probing)
  of 1: return deviceCount(tracker.initialized)
  of 2: return deviceCount(tracker.running)
  of 3: return deviceCount(tracker.suspended)
  of 4: return deviceCount(tracker.error)
  of 5: return deviceCount(tracker.removed)
  else: return 0

proc getDevicesInState*(tracker: DeviceStateTracker, state: uint32): seq[uint32] =
  ## Get all devices in specific state
  # Strategy: Iterate roaring bitmap to build list
  # TODO: Implement iterator over roaring bitmaps to avoid copy
  case state
  of 0: return iterateDevices(tracker.probing)
  of 1: return iterateDevices(tracker.initialized)
  of 2: return iterateDevices(tracker.running)
  of 3: return iterateDevices(tracker.suspended)
  of 4: return iterateDevices(tracker.error)
  of 5: return iterateDevices(tracker.removed)
  else: return @[]

# ═══════════════════════════════════════════════════════════════════════════
# Bus Device Tracking
# ═══════════════════════════════════════════════════════════════════════════

proc initBusDeviceTracker*(): BusDeviceTracker =
  ## Initialize empty bus tracker
  result.pciDevices = initDeviceSet()
  result.usbDevices = initDeviceSet()
  result.acpiDevices = initDeviceSet()
  result.platformDevices = initDeviceSet()
  result.isaDevices = initDeviceSet()

proc addDeviceToBus*(tracker: var BusDeviceTracker, deviceId: uint32, busType: uint32) =
  ## Add device to bus-specific tracker
  # Strategy: Add to appropriate compressed set
  case busType
  of 0: addDevice(tracker.pciDevices, deviceId)      # dbtPci
  of 1: addDevice(tracker.usbDevices, deviceId)      # dbtUsb
  of 2: addDevice(tracker.acpiDevices, deviceId)     # dbtAcpi
  of 3: addDevice(tracker.platformDevices, deviceId) # dbtPlatform
  of 4: addDevice(tracker.isaDevices, deviceId)      # dbtIsa
  else: discard

proc getDevicesOnBus*(tracker: BusDeviceTracker, busType: uint32): seq[uint32] =
  ## Get all devices on specific bus
  # Strategy: Iterate roaring bitmap for bus
  case busType
  of 0: return iterateDevices(tracker.pciDevices)
  of 1: return iterateDevices(tracker.usbDevices)
  of 2: return iterateDevices(tracker.acpiDevices)
  of 3: return iterateDevices(tracker.platformDevices)
  of 4: return iterateDevices(tracker.isaDevices)
  else: return @[]

proc countDevicesOnBus*(tracker: BusDeviceTracker, busType: uint32): uint32 =
  ## Get count of devices on specific bus
  case busType
  of 0: return deviceCount(tracker.pciDevices)
  of 1: return deviceCount(tracker.usbDevices)
  of 2: return deviceCount(tracker.acpiDevices)
  of 3: return deviceCount(tracker.platformDevices)
  of 4: return deviceCount(tracker.isaDevices)
  else: return 0

# ═══════════════════════════════════════════════════════════════════════════
# Device Type Tracking
# ═══════════════════════════════════════════════════════════════════════════

proc initDeviceTypeTracker*(): DeviceTypeTracker =
  ## Initialize empty type tracker
  result.charDevices = initDeviceSet()
  result.blockDevices = initDeviceSet()
  result.networkDevices = initDeviceSet()
  result.miscDevices = initDeviceSet()

proc addDeviceType*(tracker: var DeviceTypeTracker, deviceId: uint32, deviceType: uint32) =
  ## Add device to type-specific tracker
  case deviceType
  of 0: addDevice(tracker.charDevices, deviceId)      # dtCharacter
  of 1: addDevice(tracker.blockDevices, deviceId)     # dtBlock
  of 2: addDevice(tracker.networkDevices, deviceId)   # dtNetwork
  of 3: addDevice(tracker.miscDevices, deviceId)      # dtMisc
  else: discard

proc getDevicesByType*(tracker: DeviceTypeTracker, deviceType: uint32): seq[uint32] =
  ## Get all devices of specific type
  case deviceType
  of 0: return iterateDevices(tracker.charDevices)
  of 1: return iterateDevices(tracker.blockDevices)
  of 2: return iterateDevices(tracker.networkDevices)
  of 3: return iterateDevices(tracker.miscDevices)
  else: return @[]

proc countDevicesByType*(tracker: DeviceTypeTracker, deviceType: uint32): uint32 =
  ## Get count of devices of specific type
  case deviceType
  of 0: return deviceCount(tracker.charDevices)
  of 1: return deviceCount(tracker.blockDevices)
  of 2: return deviceCount(tracker.networkDevices)
  of 3: return deviceCount(tracker.miscDevices)
  else: return 0

# ═══════════════════════════════════════════════════════════════════════════
# Interrupt Mapping
# ═══════════════════════════════════════════════════════════════════════════

proc initInterruptMapping*(): InterruptMapping =
  ## Initialize empty interrupt to device mapping
  for i in 0..<256:
    result.irqDevices[i] = initDeviceSet()

proc mapDeviceToIrq*(mapping: var InterruptMapping, deviceId: uint32, irq: uint8) =
  ## Map device to IRQ (devices can share IRQs)
  # Strategy: Add device to IRQ's device set
  # Multiple devices can be associated with same IRQ
  addDevice(mapping.irqDevices[irq], deviceId)

proc unmapDeviceFromIrq*(mapping: var InterruptMapping, deviceId: uint32, irq: uint8) =
  ## Unmap device from IRQ
  removeDevice(mapping.irqDevices[irq], deviceId)

proc getDevicesForIrq*(mapping: InterruptMapping, irq: uint8): seq[uint32] =
  ## Get all devices associated with IRQ
  # Strategy: Iterate roaring bitmap for IRQ
  # O(k) where k is number of devices on that IRQ
  return iterateDevices(mapping.irqDevices[irq])

proc deviceCountOnIrq*(mapping: InterruptMapping, irq: uint8): uint32 =
  ## Get count of devices on IRQ (for interrupt balancing)
  return deviceCount(mapping.irqDevices[irq])

# ═══════════════════════════════════════════════════════════════════════════
# Statistics and Debugging
# ═══════════════════════════════════════════════════════════════════════════

proc registryStatistics*(registry: DeviceRegistry): string =
  ## Get formatted registry statistics
  let total = deviceCountArsenal(registry)
  return "Device Registry: " & $total & " devices"

proc stateStatistics*(tracker: DeviceStateTracker): string =
  ## Get formatted state distribution
  var result = "Device States:\\n"
  result = result & "  Probing: " & $countDevicesInState(tracker, 0) & "\\n"
  result = result & "  Initialized: " & $countDevicesInState(tracker, 1) & "\\n"
  result = result & "  Running: " & $countDevicesInState(tracker, 2) & "\\n"
  result = result & "  Suspended: " & $countDevicesInState(tracker, 3) & "\\n"
  result = result & "  Error: " & $countDevicesInState(tracker, 4) & "\\n"
  result = result & "  Removed: " & $countDevicesInState(tracker, 5) & "\\n"
  return result

proc busStatistics*(tracker: BusDeviceTracker): string =
  ## Get formatted bus device distribution
  var result = "Devices by Bus:\\n"
  result = result & "  PCI: " & $countDevicesOnBus(tracker, 0) & "\\n"
  result = result & "  USB: " & $countDevicesOnBus(tracker, 1) & "\\n"
  result = result & "  ACPI: " & $countDevicesOnBus(tracker, 2) & "\\n"
  result = result & "  Platform: " & $countDevicesOnBus(tracker, 3) & "\\n"
  result = result & "  ISA: " & $countDevicesOnBus(tracker, 4) & "\\n"
  return result

# ═══════════════════════════════════════════════════════════════════════════
# Design Notes
# ═══════════════════════════════════════════════════════════════════════════
##
## Memory Efficiency of Roaring Bitmaps:
##
## Array of device IDs (simple):
## - 256 devices × 4 bytes = 1 KB per tracker
## - Linear scan to find devices: O(256)
##
## Roaring Bitmap (arsenal):
## - Sparse encoding: typically 100-200 bytes for 256 devices
## - Fast iteration and set operations: O(log n)
## - Set operations (union, intersection): O(n + m)
##
## When a system has 1000+ devices:
## - Simple array: 4 KB per tracker, O(1000) scans
## - Roaring bitmap: 500 bytes, O(log 1000) lookups
##
## Benefits of this tracking approach:
## - Efficient device enumeration by any dimension (state, bus, type, IRQ)
## - O(1) membership tests (contains device?)
## - Fast state transitions without rescanning array
## - Set operations for finding devices by multiple criteria
## - Memory-efficient for sparse device sets
##
## Integration with existing device.nim:
## - Complements the flat device table lookup (linear by ID)
## - Accelerates enumeration queries significantly
## - Useful for systems with high device churn
## - Non-intrusive: works alongside existing code
