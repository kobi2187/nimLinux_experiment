# SPDX-License-Identifier: GPL-2.0
## Init Process and System Bootup
##
## First user-space process (PID 1)
## Responsible for starting all system services and the shell

import ../core/types
import ../kern/boot
import ../kern/process
import ./services
import ./app
import ./shell
import ./bundles
import ./message

type
  # ═══════════════════════════════════════════════════════════════════════════
  # Init Types
  # ═══════════════════════════════════════════════════════════════════════════

  InitPhase* = enum
    ## Init system bootup phases
    ipStartServices = 0             ## Start core services
    ipStartShell = 1                ## Start interactive shell
    ipWaitShell = 2                 ## Wait for shell to exit
    ipShutdown = 3                  ## System shutdown

  InitState* = object
    ## Init process state
    phase*: InitPhase
    isRunning*: bool
    shellId*: uint32
    services*: array[32, uint32]    ## Service IDs
    serviceCount*: uint32

# ═══════════════════════════════════════════════════════════════════════════
# Global Init State
# ═══════════════════════════════════════════════════════════════════════════

var gInitState*: InitState

# ═══════════════════════════════════════════════════════════════════════════
# Phase 1: Start Core Services
# ═══════════════════════════════════════════════════════════════════════════

proc init_phase_services*(): bool =
  ## Start all core system services
  gInitState.phase = ipStartServices

  # Start core services in dependency order
  if not start_core_services():
    return false

  return true

# ═══════════════════════════════════════════════════════════════════════════
# Phase 2: Register System Bundles
# ═══════════════════════════════════════════════════════════════════════════

proc init_phase_bundles*(): bool =
  ## Register and scan application bundles
  create_system_bundles()
  let count = scan_bundle_directory()
  # Now system is ready to launch applications
  return true

# ═══════════════════════════════════════════════════════════════════════════
# Phase 3: Start Interactive Shell
# ═══════════════════════════════════════════════════════════════════════════

proc init_phase_shell*(): bool =
  ## Start interactive shell on console
  gInitState.phase = ipStartShell

  # Create shell session
  let shellId = shell_create()
  if shellId == 0:
    return false

  gInitState.shellId = shellId

  # Print welcome message
  # Would call shell_main_loop(shellId)

  return true

# ═══════════════════════════════════════════════════════════════════════════
# Phase 4: Wait for Shell
# ═══════════════════════════════════════════════════════════════════════════

proc init_phase_wait_shell*(): bool =
  ## Wait for shell to exit
  gInitState.phase = ipWaitShell

  # Main init loop - wait for shell and handle service restarts
  while gInitState.isRunning:
    # Check shell status
    if gInitState.shellId < 8:  # Max shells
      # Would check if shell still running
      discard

    # Check service health
    # Restart any crashed services
    # Would use message-based health checks

    # Yield to other processes
    # usleep(100000)  # 100ms

  return true

# ═══════════════════════════════════════════════════════════════════════════
# Phase 5: Shutdown
# ═══════════════════════════════════════════════════════════════════════════

proc init_phase_shutdown*(): bool =
  ## System shutdown
  gInitState.phase = ipShutdown
  gInitState.isRunning = false

  # Gracefully stop services
  # Sync file systems
  # Power down

  return true

# ═══════════════════════════════════════════════════════════════════════════
# Init Main Entry Point
# ═══════════════════════════════════════════════════════════════════════════

proc init_main*() {.noReturn.} =
  ## Init process main function (runs as PID 1)
  ##
  ## This is the first user-space process
  ## Called after kernel boot is complete

  # Initialize state
  gInitState.isRunning = true
  gInitState.serviceCount = 0

  # Phase 1: Start core services
  if not init_phase_services():
    # Failed to start services - panic
    # System cannot continue
    return

  # Phase 2: Register and scan bundles
  if not init_phase_bundles():
    return

  # Phase 3: Start shell
  if not init_phase_shell():
    return

  # Phase 4: Main loop - wait for shell
  if not init_phase_wait_shell():
    return

  # Phase 5: Shutdown
  if not init_phase_shutdown():
    return

  # Exit (this should halt the system)
  # exit(0)

# ═══════════════════════════════════════════════════════════════════════════
# Init Information Functions
# ═══════════════════════════════════════════════════════════════════════════

proc init_get_status*(): string =
  ## Get init system status
  case gInitState.phase
  of ipStartServices:
    return "Init: Starting core services..."
  of ipStartShell:
    return "Init: Starting shell..."
  of ipWaitShell:
    return "Init: Shell active"
  of ipShutdown:
    return "Init: System shutting down"

proc init_get_services*(): seq[uint32] =
  ## Get list of started services
  result = @[]
  for i in 0..<gInitState.serviceCount:
    result.add(gInitState.services[i])

# ═══════════════════════════════════════════════════════════════════════════
# Boot Banner
# ═══════════════════════════════════════════════════════════════════════════

proc print_boot_banner*() =
  ## Print system boot banner
  # Would output:
  # "================================"
  # "   NimixOS - BeOS-Style Kernel"
  # "   Version 0.2.0-alpha"
  # "================================"
  # ""
  # "Boot complete. Init process starting..."
  discard

# ═══════════════════════════════════════════════════════════════════════════
# Entry Point Selector
# ═══════════════════════════════════════════════════════════════════════════

proc system_main*(bootStatus: int32) {.noReturn.} =
  ## System main entry point
  ## Called from kernel boot sequence (kernel_main)
  ##
  ## At this point:
  ## - All kernel subsystems initialized
  ## - Memory management operational
  ## - Interrupts and timers running
  ## - Scheduler ready
  ## - IPC/message system running
  ## - Services framework available
  ##
  ## Now we:
  ## 1. Print banner
  ## 2. Create and start init process
  ## 3. Kernel enters scheduler

  if bootStatus != 0:
    # Boot failed
    return

  print_boot_banner()

  # Create init process (PID 1)
  let initPid = createProcess(0, ppNormal)  # Parent PID 0 (kernel)
  if initPid == 0:
    # Failed to create init
    return

  # Set up init process memory and resources
  # setProcessMemoryLayout(initPid, HeapStart, StackStart)

  # Start init process
  setProcessState(initPid, psRunning)

  # Call init_main (this becomes the init process)
  # It will not return
  init_main()
