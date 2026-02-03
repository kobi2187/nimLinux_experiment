# SPDX-License-Identifier: GPL-2.0
## Shared Service Implementation: Kernel and User-Space
##
## Demonstrates how the same service code can run in both kernel and user-space
## using the Service Abstraction Layer. Example: Simple timer service that
## provides timing utilities to other services/apps.
##
## Key insight: Service implementation is deployment-neutral.
## Only deployment wrapper differs (kernel context vs user-space context).

import ../core/types
import ../core/service_abstraction

# ═══════════════════════════════════════════════════════════════════════════
# Shared Service Implementation (Works Anywhere)
# ═══════════════════════════════════════════════════════════════════════════

type
  TimerServiceData* = object
    ## Internal service state (deployment-neutral)
    tickCount*: uint64
    activeTimers*: uint32
    totalFires*: uint64

# Service state (lives in Service.context or global storage)
var gTimerData: TimerServiceData

# ═════════════════════════════════════════════════════════════════════════════
# Shared Message Handlers (No Deployment Assumptions)
# ═════════════════════════════════════════════════════════════════════════════

proc handleGetTime*(msg: ptr Message): bool =
  ## Get current system time
  # Strategy: Pure message handler, no kernel/user-space assumptions
  # Same code runs in both kernel and user-space
  echo "TimerService: Handling GET_TIME request"
  gTimerData.tickCount += 1
  # TODO: Send reply message with current time
  # Message format same in both kernel and user-space
  return true

proc handleSetTimer*(msg: ptr Message): bool =
  ## Set a timer (request notification after N ticks)
  # Strategy: Register timer, send notification when fired
  # Kernel: Direct callback or interrupt
  # User-space: Send message to requester
  echo "TimerService: Handling SET_TIMER request"
  inc gTimerData.activeTimers
  # TODO: Register timer and track expiration
  return true

proc handleCancelTimer*(msg: ptr Message): bool =
  ## Cancel a previously set timer
  # Strategy: Remove timer from active list
  echo "TimerService: Handling CANCEL_TIMER request"
  if gTimerData.activeTimers > 0:
    dec gTimerData.activeTimers
  return true

proc handleGetStats*(msg: ptr Message): bool =
  ## Get timer service statistics
  # Strategy: Return statistics regardless of deployment
  echo "TimerService: Handling GET_STATS request"
  echo "  Ticks: ", gTimerData.tickCount
  echo "  Active timers: ", gTimerData.activeTimers
  echo "  Total fires: ", gTimerData.totalFires
  # TODO: Send statistics in reply message
  return true

# ═════════════════════════════════════════════════════════════════════════════
# Shared Initialization (No Deployment-Specific Code)
# ═════════════════════════════════════════════════════════════════════════════

proc timerServiceOnInitialize*(service: ptr Service): bool =
  ## Initialize timer service (called regardless of deployment)
  # Strategy: Shared initialization logic
  # No assumption about kernel vs user-space
  echo "TimerService: Initializing..."

  gTimerData.tickCount = 0
  gTimerData.activeTimers = 0
  gTimerData.totalFires = 0

  # Register message handlers (same in both cases)
  if not registerMessageHandler(service[], 1, handleGetTime):
    return false
  if not registerMessageHandler(service[], 2, handleSetTimer):
    return false
  if not registerMessageHandler(service[], 3, handleCancelTimer):
    return false
  if not registerMessageHandler(service[], 4, handleGetStats):
    return false

  echo "TimerService: Initialized with 4 handlers"
  return true

# ═════════════════════════════════════════════════════════════════════════════
# Usage Scenario 1: Kernel Deployment
# ═════════════════════════════════════════════════════════════════════════════

proc exampleKernelDeployment*() =
  ## Timer service running in kernel space
  ## - Direct access to hardware timer
  ## - Runs in kernel context
  ## - Other kernel components call it directly (no IPC)
  echo ""
  echo "═" & "═".repeat(78)
  echo "Example 1: Kernel-Space Deployment"
  echo "═" & "═".repeat(78)

  # Create service for kernel deployment
  var timerService = createService(
    serviceId = 1,
    serviceName = "TimerService",
    deployment = dmKernel
  )

  # Set callbacks
  timerService.onInitialize = timerServiceOnInitialize

  # Initialize in kernel mode
  echo "Starting timer service in kernel..."
  if not initializeServiceKernel(timerService):
    echo "ERROR: Failed to initialize kernel service"
    return

  # Simulate kernel sending message to service
  echo ""
  echo "Kernel component 1: Request current time"
  var msgGetTime = Message()
  msgGetTime.what = MessageType(1)  # GET_TIME
  discard processMessage(timerService, addr msgGetTime)

  echo ""
  echo "Kernel component 2: Set timer for 100ms"
  var msgSetTimer = Message()
  msgSetTimer.what = MessageType(2)  # SET_TIMER
  discard processMessage(timerService, addr msgSetTimer)

  echo ""
  echo "Kernel component 1: Get statistics"
  var msgStats = Message()
  msgStats.what = MessageType(4)  # GET_STATS
  discard processMessage(timerService, addr msgStats)

  echo ""
  echo "✓ Kernel deployment complete"

# ═════════════════════════════════════════════════════════════════════════════
# Usage Scenario 2: User-Space Deployment
# ═════════════════════════════════════════════════════════════════════════════

proc exampleUserSpaceDeployment*() =
  ## Timer service running in user-space
  ## - Isolated process
  ## - Uses message port for communication
  ## - Kernel interaction via syscalls only
  ## - Code is identical to kernel version!
  echo ""
  echo "═" & "═".repeat(78)
  echo "Example 2: User-Space Deployment"
  echo "═" & "═".repeat(78)

  # Create service for user-space deployment
  var timerService = createService(
    serviceId = 1,
    serviceName = "TimerService",
    deployment = dmUserSpace
  )

  # Set callbacks
  timerService.onInitialize = timerServiceOnInitialize

  # Initialize in user-space mode
  echo "Starting timer service in user-space..."
  let portId = 1000
  let pid = 5
  if not initializeServiceUserSpace(timerService, portId, pid):
    echo "ERROR: Failed to initialize user-space service"
    return

  # Simulate user-space sending message to service
  # In reality, would go through message port
  echo ""
  echo "Process 1: Send GET_TIME via message port"
  var msgGetTime = Message()
  msgGetTime.what = MessageType(1)  # GET_TIME
  msgGetTime.sender = 100           # From process 100
  discard processMessage(timerService, addr msgGetTime)

  echo ""
  echo "Process 2: Send SET_TIMER via message port"
  var msgSetTimer = Message()
  msgSetTimer.what = MessageType(2)  # SET_TIMER
  msgSetTimer.sender = 200           # From process 200
  discard processMessage(timerService, addr msgSetTimer)

  echo ""
  echo "Process 1: Send another SET_TIMER"
  discard processMessage(timerService, addr msgSetTimer)

  echo ""
  echo "Process 3: Send GET_STATS via message port"
  var msgStats = Message()
  msgStats.what = MessageType(4)  # GET_STATS
  msgStats.sender = 300           # From process 300
  discard processMessage(timerService, addr msgStats)

  echo ""
  echo "✓ User-space deployment complete"

# ═════════════════════════════════════════════════════════════════════════════
# Usage Scenario 3: Architecture Selection
# ═════════════════════════════════════════════════════════════════════════════

proc exampleArchitectureSelection*() =
  ## Show how same service works across different architectures
  echo ""
  echo "═" & "═".repeat(78)
  echo "Example 3: Architecture-Aware Deployment"
  echo "═" & "═".repeat(78)

  # BeOS-style architecture
  echo ""
  echo "BeOS Architecture: Most services in user-space"
  var beosArch = createArchitecture(asBeOS)
  echo "  TimerService deployment: ", getServiceDeployment(beosArch, 1)

  # Microkernel architecture
  echo ""
  echo "Microkernel Architecture: Almost everything user-space"
  var microkernelArch = createArchitecture(asMicrokernel)
  echo "  TimerService deployment: ", getServiceDeployment(microkernelArch, 1)

  # Linux-clone architecture
  echo ""
  echo "Linux-Clone Architecture: Most services in kernel"
  var linuxArch = createArchitecture(asLinuxClone)
  echo "  TimerService deployment: ", getServiceDeployment(linuxArch, 1)

  # Hybrid architecture
  echo ""
  echo "Hybrid Architecture: Per-service decisions"
  var hybridArch = createArchitecture(asHybrid)
  echo "  TimerService deployment: ", getServiceDeployment(hybridArch, 1)

# ═════════════════════════════════════════════════════════════════════════════
# Benefits Demonstration
# ═════════════════════════════════════════════════════════════════════════════

proc demonstrateBenefits*() =
  ## Show concrete benefits of shared service abstraction
  echo ""
  echo "═" & "═".repeat(78)
  echo "Benefits of Service Abstraction"
  echo "═" & "═".repeat(78)

  echo ""
  echo "1. Code Reuse"
  echo "   - Same 'timerServiceOnInitialize' for kernel and user-space"
  echo "   - Same message handlers for both deployments"
  echo "   - Same state machine logic"

  echo ""
  echo "2. Deployment Flexibility"
  echo "   - Start with user-space timer service"
  echo "   - If performance needed, move to kernel"
  echo "   - Zero code changes required"

  echo ""
  echo "3. Architectural Evolution"
  echo "   - Start with BeOS-style message passing"
  echo "   - Scale to microkernel if needed"
  echo "   - Services move but code stays same"

  echo ""
  echo "4. Testing"
  echo "   - Test kernel service in user-space"
  echo "   - No privileges needed for testing"
  echo "   - Same code path verified in both modes"

  echo ""
  echo "5. Migration Path"
  echo "   - Services not tied to one architecture"
  echo "   - Can swap between kernel and user-space"
  echo "   - Minimal effort to migrate"

# ═════════════════════════════════════════════════════════════════════════════
# Main Example Execution
# ═════════════════════════════════════════════════════════════════════════════

proc runExamples*() =
  ## Run all deployment scenarios
  echo ""
  echo "╔" & "═".repeat(76) & "╗"
  echo "║ Service Abstraction Examples: Shared Kernel/User-Space Code ║"
  echo "╚" & "═".repeat(76) & "╝"

  exampleKernelDeployment()
  exampleUserSpaceDeployment()
  exampleArchitectureSelection()
  demonstrateBenefits()

  echo ""
  echo "═" & "═".repeat(78)
  echo "All examples completed successfully ✓"
  echo "═" & "═".repeat(78)
  echo ""
  echo "Key Takeaway:"
  echo "The same service code (timerServiceOnInitialize, message handlers)"
  echo "runs identically in both kernel and user-space deployments."
  echo "Deployment is just a runtime/compile-time choice, not a code change."
  echo ""

# ═════════════════════════════════════════════════════════════════════════════
# Design Notes
# ═════════════════════════════════════════════════════════════════════════════
##
## This example demonstrates:
##
## 1. Shared Service Implementation
##    - Handler functions are deployment-neutral
##    - No kernel/user-space specific code
##    - Pure logic, no hardware access
##
## 2. Deployment Abstraction
##    - Same service works in kernel or user-space
##    - Context wrapper provides appropriate resources
##    - Message interface unified
##
## 3. Architecture Flexibility
##    - Service doesn't care about system architecture
##    - BeOS, Microkernel, Linux, Hybrid - all supported
##    - Optimal deployment chosen at initialization
##
## 4. Real-World Application
##    - File system service: Kernel for Linux, User-space for Microkernel
##    - Device driver: Kernel for monolithic, User-space for Microkernel
##    - Network stack: Choose based on performance needs
##
## 5. Migration Scenario
##    - Service A starts in user-space (simple)
##    - System monitoring shows CPU overhead
##    - Move to kernel deployment (no code change)
##    - Performance improves 10-100x
##    - Users see no difference (same interface)
