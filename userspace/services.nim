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
# Service Lifecycle - Forth-style: validation then operations
# ═══════════════════════════════════════════════════════════════════════════

proc service_validate(serviceId: uint32): bool =
  ## Check if service ID is valid
  # Strategy: Bounds check
  return serviceId < gServiceCount

proc service_get(serviceId: uint32): ptr Service =
  ## Get service by ID
  # Strategy: Index array if valid
  if not service_validate(serviceId):
    return nil
  return addr gServices[serviceId]

proc service_status_is_active(status: ServiceStatus): bool =
  ## Check if status represents active service
  # Strategy: Status is active if running or initializing
  return status == stsRunning or status == stsInitializing

proc string_to_service_name(src: cstring): array[64, uint8] =
  ## Convert cstring to fixed-size name
  # Strategy: Copy until null or 64 bytes
  var result: array[64, uint8]
  if src != nil:
    var i = 0
    while i < 63:
      let byte = cast[ptr uint8](cast[uint64](src) + i)[]
      if byte == 0:
        break
      result[i] = byte
      i += 1
    result[i] = 0
  return result

proc register_service*(serviceType: ServiceType, name: cstring): uint32 =
  ## Register a service (called by service on startup)
  # Strategy: Allocate service, create port and looper, register type
  if gServiceCount >= MaxServices:
    return 0

  var service: Service
  service.serviceId = gServiceCount
  service.serviceType = serviceType
  service.name = string_to_service_name(name)

  service.portId = createPort(DefaultPortCapacity, name)
  if service.portId == 0:
    return 0

  service.looperId = createLooper(name)
  if service.looperId == 0:
    return 0

  service.status = stsInitializing
  service.processId = 0  # Would be actual PID
  service.priority = 128  # Default priority

  gServices[gServiceCount] = service
  let id = gServiceCount
  inc gServiceCount

  # Register in well-known port list for quick lookup
  if ord(serviceType) < WellKnownPortCount:
    gWellKnownPorts[ord(serviceType)] = service.portId

  return uint32(id)

proc unregister_service*(serviceId: uint32): bool =
  ## Unregister a service (shutdown)
  # Strategy: Mark as stopped, clean up resources
  let service = service_get(serviceId)
  if service == nil:
    return false

  service.status = stsStopped
  discard stopLooper(service.looperId)
  return true

proc get_service*(serviceType: ServiceType): uint32 =
  ## Get port ID of service by type (quick lookup)
  # Strategy: Index well-known ports array
  if ord(serviceType) < WellKnownPortCount:
    return gWellKnownPorts[ord(serviceType)]
  return 0

proc find_service*(name: cstring): uint32 =
  ## Find service port by name (linear search)
  # Strategy: Search services for matching name, return port
  if name == nil:
    return 0

  for i in 0..<gServiceCount:
    if service_status_is_active(gServices[i].status):
      # Compare names
      var nameMatches = true
      for j in 0..<64:
        let serviceNameByte = gServices[i].name[j]
        let queryNameByte = cast[ptr uint8](cast[uint64](name) + j)[]
        if serviceNameByte == 0 and queryNameByte == 0:
          break
        if serviceNameByte != queryNameByte:
          nameMatches = false
          break
      if nameMatches:
        return gServices[i].portId

  return 0

proc service_get_port(serviceId: uint32): uint32 =
  ## Get port ID from service
  # Strategy: Look up port from service struct
  let service = service_get(serviceId)
  if service == nil:
    return 0
  return service.portId

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
# Service Discovery and Queries - Monitoring and introspection
# ═══════════════════════════════════════════════════════════════════════════

proc count_running_services*(): uint32 =
  ## Count running services
  # Strategy: Iterate services, count active ones
  var count = 0'u32
  for i in 0..<gServiceCount:
    if gServices[i].status == stsRunning:
      inc count
  return count

proc count_paused_services*(): uint32 =
  ## Count paused services
  # Strategy: Iterate services, count paused ones
  var count = 0'u32
  for i in 0..<gServiceCount:
    if gServices[i].status == stsPaused:
      inc count
  return count

proc list_services*(): string =
  ## List all services with status
  # Strategy: Iterate services, format each one
  var result = "System Services:\n"
  for i in 0..<gServiceCount:
    let srv = addr gServices[i]
    let status = case srv.status
      of stsRunning: "RUN"
      of stsPaused: "PSD"
      of stsInitializing: "INI"
      of stsStopping: "STP"
      of stsStopped: "OFF"
      of stsError: "ERR"
    result = result & "  [" & status & "] Service " & $i & " (Type: " & $ord(srv.serviceType) & ")\n"
  return result

proc list_services_by_type*(serviceType: ServiceType): string =
  ## List all services of given type
  # Strategy: Iterate services, show matching types
  var result = "Services of type " & $ord(serviceType) & ":\n"
  var count = 0
  for i in 0..<gServiceCount:
    if gServices[i].serviceType == serviceType:
      result = result & "  Service " & $i & ": " & $gServices[i].status & "\n"
      inc count
  if count == 0:
    result = result & "  (none)\n"
  return result

proc get_service_info*(serviceId: uint32): string =
  ## Get formatted service information
  # Strategy: Look up service, format its details
  let service = service_get(serviceId)
  if service == nil:
    return "Service not found"

  let status = case service.status
    of stsRunning: "Running"
    of stsPaused: "Paused"
    of stsInitializing: "Initializing"
    of stsStopping: "Stopping"
    of stsStopped: "Stopped"
    of stsError: "Error"

  return "Service " & $serviceId & ": Type=" & $ord(service.serviceType) &
         " Status=" & status & " Port=" & $service.portId

proc services_stats*(): string =
  ## Get service statistics
  # Strategy: Count services in each state
  let running = count_running_services()
  let paused = count_paused_services()
  return "Services: " & $running & " running, " & $paused & " paused, " &
         $gServiceCount & " total"

proc service_port_lookup*(serviceType: ServiceType): uint32 =
  ## Lookup service port by type
  # Strategy: Query well-known ports or search by type
  let portId = get_service(serviceType)
  if portId != 0:
    return portId

  # Fallback to linear search
  for i in 0..<gServiceCount:
    if gServices[i].serviceType == serviceType and
       service_status_is_active(gServices[i].status):
      return gServices[i].portId

  return 0
