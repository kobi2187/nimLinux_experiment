# SPDX-License-Identifier: GPL-2.0
## System Services and Daemons
##
## Core system services that manage resources
## Designed as cooperating message-based services (BeOS style)

import ../core/types
import ./message

type
  # ═══════════════════════════════════════════════════════════════════════════
  # Service Types
  # ═══════════════════════════════════════════════════════════════════════════

  ServiceType* = enum
    ## Core system services
    srvAppServer = 0                ## GUI/window server
    srvMidiServer = 1               ## Audio/MIDI services
    srvMediaServer = 2              ## Video/media playback
    srvPrintServer = 3              ## Print spooler
    srvStorageServer = 4            ## File system services
    srvNetworkServer = 5            ## Network services
    srvRegistrar = 6                ## Application registry
    srvCertificateServer = 7        ## Certificate/security
    srvInputServer = 8              ## Keyboard/mouse input
    srvDebugServer = 9              ## Debugging services

  ServiceStatus* = enum
    stsInitializing
    stsRunning
    stsPaused
    stsStopping
    stsStopped
    stsError

  Service* = object
    ## Registered system service
    serviceId*: uint32
    serviceType*: ServiceType
    name*: array[64, uint8]
    portId*: uint32
    looperId*: uint32
    status*: ServiceStatus
    processId*: uint32
    priority*: uint8

# ═══════════════════════════════════════════════════════════════════════════
# Service Registry
# ═══════════════════════════════════════════════════════════════════════════

const
  MaxServices* = 32
  WellKnownPortCount* = 10

var
  gServices*: array[MaxServices, Service]
  gServiceCount*: uint32 = 0
  gWellKnownPorts*: array[WellKnownPortCount, uint32]  ## Standard service ports

# ═══════════════════════════════════════════════════════════════════════════
# Service Lifecycle
# ═══════════════════════════════════════════════════════════════════════════

proc register_service*(serviceType: ServiceType, name: cstring): uint32 =
  ## Register a service (called by service on startup)
  if gServiceCount >= MaxServices:
    return 0

  var service: Service
  service.serviceId = gServiceCount
  service.serviceType = serviceType
  service.portId = createPort()
  service.looperId = createLooper(name)
  service.status = stsInitializing

  gServices[gServiceCount] = service
  let id = gServiceCount
  inc gServiceCount

  # Register in well-known port list
  if ord(serviceType) < WellKnownPortCount:
    gWellKnownPorts[ord(serviceType)] = service.portId

  return uint32(id)

proc unregister_service*(serviceId: uint32): bool =
  ## Unregister a service
  if serviceId >= gServiceCount:
    return false
  # Mark as stopped
  gServices[serviceId].status = stsStopped
  return true

proc get_service*(serviceType: ServiceType): uint32 =
  ## Get port ID of service by type
  if ord(serviceType) < WellKnownPortCount:
    return gWellKnownPorts[ord(serviceType)]
  return 0

proc find_service*(name: cstring): uint32 =
  ## Find service port by name
  for i in 0..<gServiceCount:
    if gServices[i].status != stsStopped:
      # Would compare name
      return gServices[i].portId
  return 0

# ═══════════════════════════════════════════════════════════════════════════
# Core System Services
# ═══════════════════════════════════════════════════════════════════════════

# AppServer - manages windows and drawing
var gAppServerPortId*: uint32 = 0

proc start_app_server*(): bool =
  ## Start application/window server
  let srvId = register_service(srvAppServer, "app_server")
  if srvId == 0:
    return false
  gAppServerPortId = gServices[srvId].portId
  gServices[srvId].status = stsRunning
  return true

# Registrar - manages application lifecycle
var gRegistrarPortId*: uint32 = 0

proc start_registrar*(): bool =
  ## Start application registrar
  let srvId = register_service(srvRegistrar, "registrar")
  if srvId == 0:
    return false
  gRegistrarPortId = gServices[srvId].portId
  gServices[srvId].status = stsRunning
  return true

# Input Server - handles keyboard/mouse
var gInputServerPortId*: uint32 = 0

proc start_input_server*(): bool =
  ## Start input server
  let srvId = register_service(srvInputServer, "input_server")
  if srvId == 0:
    return false
  gInputServerPortId = gServices[srvId].portId
  gServices[srvId].status = stsRunning
  return true

# Media Server - handles audio/video
var gMediaServerPortId*: uint32 = 0

proc start_media_server*(): bool =
  ## Start media server
  let srvId = register_service(srvMediaServer, "media_server")
  if srvId == 0:
    return false
  gMediaServerPortId = gServices[srvId].portId
  gServices[srvId].status = stsRunning
  return true

# Storage Server - handles file system
var gStorageServerPortId*: uint32 = 0

proc start_storage_server*(): bool =
  ## Start storage/file system server
  let srvId = register_service(srvStorageServer, "storage_server")
  if srvId == 0:
    return false
  gStorageServerPortId = gServices[srvId].portId
  gServices[srvId].status = stsRunning
  return true

# Network Server - handles networking
var gNetworkServerPortId*: uint32 = 0

proc start_network_server*(): bool =
  ## Start network server
  let srvId = register_service(srvNetworkServer, "net_server")
  if srvId == 0:
    return false
  gNetworkServerPortId = gServices[srvId].portId
  gServices[srvId].status = stsRunning
  return true

# ═══════════════════════════════════════════════════════════════════════════
# Service Management
# ═══════════════════════════════════════════════════════════════════════════

proc set_service_status*(serviceId: uint32, status: ServiceStatus): bool =
  ## Change service status
  if serviceId >= gServiceCount:
    return false
  gServices[serviceId].status = status
  return true

proc get_service_status*(serviceId: uint32): ServiceStatus =
  ## Get service status
  if serviceId >= gServiceCount:
    return stsStopped
  return gServices[serviceId].status

proc pause_service*(serviceId: uint32): bool =
  ## Pause a service
  if serviceId >= gServiceCount:
    return false
  gServices[serviceId].status = stsPaused
  return true

proc resume_service*(serviceId: uint32): bool =
  ## Resume a paused service
  if serviceId >= gServiceCount:
    return false
  if gServices[serviceId].status == stsPaused:
    gServices[serviceId].status = stsRunning
    return true
  return false

# ═══════════════════════════════════════════════════════════════════════════
# Boot-Time Service Initialization
# ═══════════════════════════════════════════════════════════════════════════

proc start_core_services*(): bool =
  ## Start all core system services in order
  ## Called during kernel boot

  # Storage must be first (other services might need it)
  if not start_storage_server():
    return false

  # Network server
  if not start_network_server():
    return false

  # Registrar (tracks applications)
  if not start_registrar():
    return false

  # App server (manages windows)
  if not start_app_server():
    return false

  # Input server (keyboard/mouse)
  if not start_input_server():
    return false

  # Media server (audio/video)
  if not start_media_server():
    return false

  return true

# ═══════════════════════════════════════════════════════════════════════════
# Service Discovery and Queries
# ═══════════════════════════════════════════════════════════════════════════

proc list_services*(): seq[uint32] =
  ## Get list of all running service ports
  result = @[]
  for i in 0..<gServiceCount:
    if gServices[i].status == stsRunning:
      result.add(gServices[i].portId)

proc get_service_info*(serviceId: uint32): string =
  ## Get formatted service information
  if serviceId >= gServiceCount:
    return "Service not found"
  let service = addr gServices[serviceId]
  "Service " & $serviceId & ": " & $service.serviceType & " (" &
  $service.status & ")"

proc services_stats*(): string =
  ## Get service statistics
  var running = 0'u32
  for i in 0..<gServiceCount:
    if gServices[i].status == stsRunning:
      inc running
  return "Services: " & $running & "/" & $gServiceCount & " running"
