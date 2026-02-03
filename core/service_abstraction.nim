# SPDX-License-Identifier: GPL-2.0
## Service Abstraction Layer
##
## Architecture-neutral service interface supporting:
## - BeOS-style message-driven architecture
## - Microkernel (minimal kernel, services in user-space)
## - Linux-clone (monolithic/modular kernel)
## - Hybrid deployments (mixed kernel/user-space services)
##
## Key principle: A service is a service. Same code can run in kernel or user-space.
## Deployment decisions are orthogonal to service implementation.

import types

type
  # ═══════════════════════════════════════════════════════════════════════════
  # Architecture and Deployment Styles
  # ═══════════════════════════════════════════════════════════════════════════

  ArchitectureStyle* = enum
    ## System architecture paradigm
    asBeOS              ## Message-driven, all services via messaging
    asMicrokernel       ## Minimal kernel, most services user-space
    asLinuxClone        ## Traditional monolithic/modular structure
    asHybrid            ## Mixed: some services kernel, some user-space

  DeploymentMode* = enum
    ## Where service runs
    dmKernel            ## Runs in kernel space (privileged)
    dmUserSpace         ## Runs in user-space (unprivileged)
    dmFlexible          ## Can run in either (implementation choice)

  ServiceState* = enum
    ## Service lifecycle state
    ssInitializing = 0
    ssRunning = 1
    ssPaused = 2
    ssStopping = 3
    ssStopped = 4
    ssError = 5

  # ═══════════════════════════════════════════════════════════════════════════
  # Service Interface (Architecture-Neutral)
  # ═══════════════════════════════════════════════════════════════════════════

  ServiceId* = distinct uint32
    ## Type-safe service identifier

  MessageHandler* = proc(msg: ptr Message): bool {.cdecl.}
    ## Generic message handler (works in both kernel and user-space)
    ## Returns true if message was handled, false if not

  ServiceContext* = object
    ## Runtime context - differs by deployment but interface is same
    case deployment*: DeploymentMode
    of dmKernel:
      # Kernel-space: direct memory access, hardware access
      kernelMemory*: pointer
      irqLevel*: uint8
    of dmUserSpace:
      # User-space: port-based messaging, syscalls
      port*: uint32
      pid*: uint32
    of dmFlexible:
      # Can adapt at runtime
      flexContext*: pointer

  Service* = object
    ## Universal service interface (works in kernel or user-space)
    ##
    ## Implementation strategy:
    ## - Kernel services link directly against library
    ## - User-space services use same library + IPC layer
    ## - Message protocol is identical in both cases
    ##
    ## This allows:
    ## - Code reuse (same implementation)
    ## - Flexible deployment (move service kernel <-> user-space)
    ## - Architectural evolution (start BeOS, move to microkernel)
    serviceId*: ServiceId
    serviceName*: cstring
    deployment*: DeploymentMode
    state*: ServiceState
    context*: ServiceContext

    # Message-based interface (works in any architecture)
    messagePort*: uint32        ## Message queue ID
    handlers*: array[256, MessageHandler]
    handlerCount*: uint32

    # Lifecycle callbacks
    onInitialize*: proc(service: ptr Service): bool
    onShutdown*: proc(service: ptr Service): bool
    onMessage*: proc(service: ptr Service, msg: ptr Message): bool

  # ═══════════════════════════════════════════════════════════════════════════
  # System Configuration
  # ═══════════════════════════════════════════════════════════════════════════

  SystemArchitecture* = object
    ## System-wide architecture configuration
    ## Can change at compile-time or runtime
    style*: ArchitectureStyle
    kernelServices*: array[32, ServiceId]    ## Services in kernel
    userSpaceServices*: array[32, ServiceId] ## Services in user-space
    kernelServiceCount*: uint32
    userSpaceServiceCount*: uint32

# ═══════════════════════════════════════════════════════════════════════════
# Service Factory - Deployment-Aware
# ═══════════════════════════════════════════════════════════════════════════

proc createService*(
  serviceId: uint32,
  serviceName: cstring,
  deployment: DeploymentMode
): Service =
  ## Create service with specified deployment mode
  ## Same code path used regardless of deployment
  result.serviceId = ServiceId(serviceId)
  result.serviceName = serviceName
  result.deployment = deployment
  result.state = ssInitializing
  result.handlerCount = 0

  case deployment
  of dmKernel:
    # Kernel service: direct memory initialization
    result.context.deployment = dmKernel
    result.context.irqLevel = 0
  of dmUserSpace:
    # User-space service: initialize for messaging
    result.context.deployment = dmUserSpace
    result.context.port = 0  # Will be assigned
    result.context.pid = 0
  of dmFlexible:
    # Flexible service: can adapt at runtime
    result.context.deployment = dmFlexible
    result.context.flexContext = nil

proc registerMessageHandler*(
  service: var Service,
  messageType: uint8,
  handler: MessageHandler
): bool =
  ## Register handler for message type (works in any deployment)
  if service.handlerCount >= 256:
    return false

  service.handlers[messageType] = handler
  inc service.handlerCount
  return true

proc processMessage*(
  service: var Service,
  msg: ptr Message
): bool =
  ## Process message (same code path for kernel and user-space)
  ##
  ## Deployment difference:
  ## - Kernel: Direct function call, runs in kernel context
  ## - User-space: Via message port, runs in service process
  ## - Interface: Identical in both cases
  if service.state != ssRunning:
    return false

  # Find and call appropriate handler
  if msg.what < 256:
    if service.handlers[uint8(msg.what)] != nil:
      return service.handlers[uint8(msg.what)](msg)

  # Fallback to generic handler if no specific one
  if service.onMessage != nil:
    return service.onMessage(addr service, msg)

  return false

# ═══════════════════════════════════════════════════════════════════════════
# Deployment-Specific Implementations (But Same Interface)
# ═══════════════════════════════════════════════════════════════════════════

# Kernel deployment
proc initializeServiceKernel*(service: var Service): bool =
  ## Initialize service for kernel deployment
  # Strategy: Service has direct kernel access
  # No IPC overhead, runs in kernel context with full privileges
  if service.deployment != dmKernel:
    return false

  # TODO: Set up kernel resources (memory, IRQ handlers, etc)
  # TODO: Call onInitialize callback
  # TODO: Mark service as running
  service.state = ssRunning
  return true

# User-space deployment
proc initializeServiceUserSpace*(service: var Service, port: uint32, pid: uint32): bool =
  ## Initialize service for user-space deployment
  # Strategy: Service runs as isolated process, uses message passing
  # All kernel interaction via syscalls, no direct hardware access
  if service.deployment != dmUserSpace:
    return false

  service.context.port = port
  service.context.pid = pid

  # TODO: Set up message port
  # TODO: Call onInitialize callback via function pointer
  # TODO: Mark service as running
  service.state = ssRunning
  return true

# Flexible deployment
proc initializeServiceFlexible*(service: var Service, mode: DeploymentMode): bool =
  ## Initialize flexible service in specified mode
  # Strategy: Service implementation adapts to deployment
  # Can switch between kernel/user-space at build time or runtime
  case mode
  of dmKernel:
    # TODO: Switch to kernel mode implementation
    return initializeServiceKernel(service)
  of dmUserSpace:
    # TODO: Switch to user-space mode implementation
    # For now, require caller to provide port/pid separately
    return false
  of dmFlexible:
    # TODO: Decide optimal deployment based on load
    return initializeServiceFlexible(service, dmUserSpace)

# ═══════════════════════════════════════════════════════════════════════════
# Architecture Configuration
# ═══════════════════════════════════════════════════════════════════════════

proc createArchitecture*(style: ArchitectureStyle): SystemArchitecture =
  ## Create system architecture with specified style
  result.style = style
  result.kernelServiceCount = 0
  result.userSpaceServiceCount = 0

  # Default service distributions by architecture
  case style
  of asBeOS:
    # BeOS: All services via message passing
    # Kernel: Just scheduler, IRQ handler, memory manager
    # User-space: Everything else (driver servers, app_server, registrar, etc)
    # TODO: Set kernel service list
    # TODO: Set user-space service list
    discard
  of asMicrokernel:
    # Microkernel: Minimal kernel
    # Kernel: Just scheduler, IPC, basic memory management
    # User-space: File system, device drivers, networking, everything else
    # TODO: Set kernel service list (very small)
    # TODO: Set user-space service list (most services)
    discard
  of asLinuxClone:
    # Linux-clone: Monolithic kernel with some user-space daemons
    # Kernel: Scheduler, memory, page cache, VFS, device drivers
    # User-space: Services (dbus, systemd-like, apps)
    # TODO: Set kernel service list (most drivers/subsystems)
    # TODO: Set user-space service list (daemons)
    discard
  of asHybrid:
    # Hybrid: Flexible deployment per service
    # Each service decides based on performance/privilege requirements
    # TODO: Set service deployment individually
    discard

proc getServiceDeployment*(
  arch: SystemArchitecture,
  serviceId: uint32
): DeploymentMode =
  ## Get deployment mode for service in this architecture
  # Strategy: Look up in architecture configuration
  # Can be specialized per architecture style
  case arch.style
  of asBeOS:
    # Most services user-space in BeOS
    if serviceId < 10:
      return dmUserSpace
    return dmUserSpace
  of asMicrokernel:
    # Almost everything user-space in microkernel
    return dmUserSpace
  of asLinuxClone:
    # Most subsystems in kernel, some daemons user-space
    if serviceId < 20:
      return dmKernel
    return dmUserSpace
  of asHybrid:
    # Service-specific decision
    return dmFlexible

# ═══════════════════════════════════════════════════════════════════════════
# Service Registry (Architecture-Aware)
# ═══════════════════════════════════════════════════════════════════════════

var gSystemArchitecture*: SystemArchitecture
var gServices*: array[64, Service]
var gServiceCount*: uint32 = 0

proc registerServiceGlobal*(service: Service): bool =
  ## Register service in global registry
  # Strategy: Add to list regardless of deployment
  # Registry works the same for kernel and user-space services
  if gServiceCount >= 64:
    return false

  gServices[gServiceCount] = service
  inc gServiceCount
  return true

proc findService*(serviceId: uint32): Option[ptr Service] =
  ## Find service by ID (same interface for all deployments)
  for i in 0..<gServiceCount:
    if uint32(gServices[i].serviceId) == serviceId:
      return some(addr gServices[i])
  return none(ptr Service)

proc getServiceStats*(serviceId: uint32): string =
  ## Get service status (same interface regardless of deployment)
  if let service = findService(serviceId):
    let mode = case service[].deployment
      of dmKernel: "kernel"
      of dmUserSpace: "user-space"
      of dmFlexible: "flexible"

    let state = case service[].state
      of ssInitializing: "initializing"
      of ssRunning: "running"
      of ssPaused: "paused"
      of ssStopping: "stopping"
      of ssStopped: "stopped"
      of ssError: "error"

    return service[].serviceName & " (" & mode & ", " & state & ")"

  return "Service not found"

# ═══════════════════════════════════════════════════════════════════════════
# Design Notes
# ═══════════════════════════════════════════════════════════════════════════
##
## Service Abstraction Philosophy:
##
## Traditional approach (architecture-specific):
## - BeOS: Everything message-driven (port-based)
## - Microkernel: Everything user-space + IPC (expensive)
## - Linux: Most in-kernel (privileged but no IPC overhead)
##
## Service abstraction approach:
## - Service code is identical
## - Deployment is orthogonal (kernel vs user-space choice)
## - Message interface works both ways
## - Can migrate services between deployments
##
## Example: File System Service
##
## Traditional:
## - Linux: In-kernel, direct memory access, IRQ handlers
## - BeOS: In user-space, only via messaging
## - Microkernel: In user-space, all IPC
##
## With Service Abstraction:
## - Write once, deploy anywhere
## - Kernel mode: Direct I/O, IRQ handlers, memory access
## - User-space mode: Syscalls, message passing, port-based
## - Same state machine, same handlers, different context
##
## Benefits:
## 1. Code reuse (write service once)
## 2. Architectural flexibility (deploy where best)
## 3. Evolution path (start BeOS, move to microkernel)
## 4. Hybrid systems (pick per-service)
## 5. Testing (test kernel service in user-space)
##
## Implementation Strategy:
## 1. Service logic is pure (no deployment-specific code)
## 2. Context wrapper provides deployment-specific resources
## 3. Message handler interface is universal
## 4. Deployment-specific init/shutdown (onInitialize, onShutdown)
## 5. At runtime, code path identical (processMessage works same)
##
## Future Enhancements:
## - Automatic deployment decision (load-based)
## - Service migration (move between kernel/user-space)
## - Privilege escalation (start user-space, move to kernel if needed)
## - Distributed services (same code across network)
