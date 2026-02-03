# SPDX-License-Identifier: GPL-2.0
## Event-Driven Scripting Examples
##
## Shows how to use event_server for automation
## BeOS-style event-driven programming

import ../core/types
import ./event_server
import ./message

# ═══════════════════════════════════════════════════════════════════════════
# Example 1: Simple Automation
# ═══════════════════════════════════════════════════════════════════════════

proc example_shutdown_on_downloads*() =
  ## "Shut down the computer once downloads are finished"
  ##
  ## This automation:
  ## 1. Listens for download completion events
  ## 2. Checks if ALL downloads are done
  ## 3. Triggers system shutdown

  let actionId = setup_shutdown_on_downloads_complete()
  enable_action(actionId)

  # Later, when a download finishes:
  # Somewhere in download_server.nim:
  #   publish_event(evtDownload, evtDownloadCompleted, app_id)
  #
  # This automatically triggers the shutdown action

# ═══════════════════════════════════════════════════════════════════════════
# Example 2: File Backup on Modify
# "Back up files whenever they're modified"
# ═══════════════════════════════════════════════════════════════════════════

proc example_auto_backup*() =
  ## Subscribe to file modification events
  ## Auto-backup service watches for these

  let backupServerPort = 0'u32  # Would get from registrar

  let actionId = setup_file_backup_on_modify(backupServerPort)
  enable_action(actionId)

  # Now whenever a file is modified:
  # - storage_server publishes evtFileModified
  # - event_server triggers backup action
  # - backup message sent to backup service

# ═══════════════════════════════════════════════════════════════════════════
# Example 3: Complex Multi-Event Trigger
# "Launch browser once downloads finish AND network is back online"
# ═══════════════════════════════════════════════════════════════════════════

var gLastNetworkEvent*: Event
var gLastDownloadEvent*: Event

proc example_conditional_launch*() =
  ## Create automation that requires multiple conditions

  # Register condition: check download size
  proc downloadLargeFile(evt: Event): bool =
    # Extract size from event data
    let fileSize = 0'u64  # Would parse from evt.data
    return fileSize > (100 * 1024 * 1024)  # > 100 MB

  # Register download action with condition
  let dlActionId = register_action(evtDownloadCompleted, "launch_browser",
    proc(evt: Event) =
      # This only runs if condition is true
      # Launch web browser
      # be_app_launch_by_name("WebBrowser")
      publish_event(evtApplication, EventCode(0x424F574D), 0)  ## "BOWM" (browser)
  )

  # Add condition
  add_action_condition(dlActionId, downloadLargeFile)
  enable_action(dlActionId)

# ═══════════════════════════════════════════════════════════════════════════
# Example 4: Event Logging Service
# "Log all important system events"
# ═══════════════════════════════════════════════════════════════════════════

var gEventLogFile*: uint32 = 0  # File handle

proc example_event_logging*() =
  ## Create action that logs all events

  let logActionId = register_action(evtSystem, "system_logger",
    proc(evt: Event) =
      # Write event to log file
      # File format: timestamp | event_type | event_code | app_id
      #
      # 2026-02-03 12:34:56 | DOWNLOAD | DLCP | app_42
      # 2026-02-03 12:34:57 | DEVICE  | DVCH | kernel

      # Pseudo-code:
      # log_line = format_time(evt.timestamp) & " | " &
      #            event_type_string(evt.eventType) & " | " &
      #            event_code_string(evt.code) & " | " &
      #            app_id_string(evt.sourceApp)
      # write_to_file(gEventLogFile, log_line)
      discard
  )

  enable_action(logActionId)

# ═══════════════════════════════════════════════════════════════════════════
# Example 5: Device Hot-Plug Handler
# "When USB device connects, mount it automatically"
# ═══════════════════════════════════════════════════════════════════════════

proc example_auto_mount_usb*() =
  ## Auto-mount USB drives when connected

  let mountActionId = register_action(evtDeviceConnected, "auto_mount",
    proc(evt: Event) =
      # Check if device is USB (from event data)
      # Call mount_device syscall
      # Update file manager view
      publish_event(evtStorage, EventCode(0x4D4E5420), 0)  ## "MNT "
  )

  enable_action(mountActionId)

# ═══════════════════════════════════════════════════════════════════════════
# Example 6: User Presence Detection
# "Close idle applications when user logs out"
# ═══════════════════════════════════════════════════════════════════════════

proc example_idle_app_cleanup*() =
  ## When user logs out, gracefully close applications

  let cleanupActionId = register_action(evtUserLogout, "cleanup_apps",
    proc(evt: Event) =
      # Get list of running applications
      # Send graceful quit message to each
      # Wait for timeout, then force quit any that didn't close

      # Pseudo-code:
      # apps = get_running_apps()
      # for app in apps:
      #   send_message(app.port, MsgQuit, 0, 0)
      #   wait_for_app_exit(app, timeout=5s)
      #   if app.still_running:
      #     kill_app(app)
      discard
  )

  enable_action(cleanupActionId)

# ═══════════════════════════════════════════════════════════════════════════
# Example 7: System Health Monitor
# "Alert when CPU usage is high"
# ═══════════════════════════════════════════════════════════════════════════

proc example_cpu_alert*() =
  ## Create custom event for high CPU and alert

  # In system monitor:
  # if cpu_usage > 80%:
  #   publish_event(evtSystem, evtHighCpu, 0)

  let alertActionId = register_action(EventCode(0x43505548), "cpu_alert",  ## "CPUH"
    proc(evt: Event) =
      # Send notification to user
      # "System CPU usage is high"
      publish_event(evtSystem, EventCode(0x414C4552), 0)  ## "ALER"
  )

  enable_action(alertActionId)

# ═══════════════════════════════════════════════════════════════════════════
# Example 8: Scripting with Complex Conditions
# "Save open files and shut down when battery is low AND AC is unplugged"
# ═══════════════════════════════════════════════════════════════════════════

var gIsBatteryLow* = false
var gIsACConnected* = true

proc example_power_event_automation*() =
  ## Power management automation

  # Condition 1: Battery is low
  proc isBatteryLow(evt: Event): bool =
    gIsBatteryLow

  # Condition 2: AC is unplugged
  proc isACUnplugged(evt: Event): bool =
    not gIsACConnected

  # Action: Save everything and shutdown
  let powerActionId = register_action(EventCode(0x50574552), "power_shutdown",  ## "PWER"
    proc(evt: Event) =
      # Save all open documents
      publish_event(evtApplication, EventCode(0x53415645), 0)  ## "SAVE"

      # Brief delay
      # sleep(1000)  # 1 second

      # Shutdown
      publish_event(evtSystem, evtShutdown, 0)
  )

  # Add both conditions (both must be true)
  add_action_condition(powerActionId, isBatteryLow)
  add_action_condition(powerActionId, isACUnplugged)

  enable_action(powerActionId)

# ═══════════════════════════════════════════════════════════════════════════
# Example 9: Event-Driven Queue Processing
# "Process job queue items as they arrive"
# ═══════════════════════════════════════════════════════════════════════════

proc example_queue_processor*() =
  ## Listen for new items in queue and process them

  let processActionId = register_action(EventCode(0x514A4F42), "process_queue",  ## "QJOB"
    proc(evt: Event) =
      # Extract job ID from event data
      let jobId = 0'u32  # Would parse from evt.data

      # Process the job
      # result = process_job(jobId)

      # Emit completion event
      publish_event(evtSystem, EventCode(0x444F4E45), 0)  ## "DONE"
  )

  enable_action(processActionId)

# ═══════════════════════════════════════════════════════════════════════════
# Example 10: Performance-Based Automation
# "Switch to power-saving mode when temperature is high"
# ═══════════════════════════════════════════════════════════════════════════

var gCPUTemperature* = 45'i32

proc example_thermal_management*() =
  ## Respond to thermal events

  proc isTempHigh(evt: Event): bool =
    gCPUTemperature > 85

  let thermalActionId = register_action(EventCode(0x54484552), "thermal_manage",  ## "THER"
    proc(evt: Event) =
      # Switch to power-saving CPU profile
      # reduce_cpu_frequency()

      # Throttle background tasks
      # throttle_background_services()

      # Alert user
      publish_event(evtSystem, EventCode(0x544F4F484F), 0)  ## "TOHO" (too hot)
  )

  add_action_condition(thermalActionId, isTempHigh)
  enable_action(thermalActionId)

# ═══════════════════════════════════════════════════════════════════════════
# System Integration
# ═══════════════════════════════════════════════════════════════════════════

proc init_all_automations*() =
  ## Set up all system automations during boot

  # Start event server
  start_event_server()

  # Register all common automations
  example_shutdown_on_downloads()
  example_auto_backup()
  example_conditional_launch()
  example_event_logging()
  example_auto_mount_usb()
  example_idle_app_cleanup()
  example_cpu_alert()
  example_power_event_automation()
  example_queue_processor()
  example_thermal_management()

# ═══════════════════════════════════════════════════════════════════════════
# Shell Commands for Event Management
# ═══════════════════════════════════════════════════════════════════════════

proc shell_cmd_event_stats*(): string =
  ## Command: "event stats"
  return event_server_stats()

proc shell_cmd_subscribe*(eventType: cstring): string =
  ## Command: "subscribe download"
  ## Subscribe shell to event type
  var evType = evtSystem
  # Parse event type string
  return "Subscribed to " & $eventType & " events"

proc shell_cmd_trigger_event*(eventCode: cstring): string =
  ## Command: "trigger shutdown"
  ## Manually trigger an event (for testing)
  # Parse event code and publish
  return "Event triggered: " & $eventCode

proc shell_cmd_list_automations*(): string =
  ## Command: "automations list"
  ## List all registered automations
  var result = "Registered Automations:\n"
  let actions = list_actions()
  for actionId in actions:
    result &= "  Action " & $actionId & "\n"
  return result

# ═══════════════════════════════════════════════════════════════════════════
# Explanation: Why This Pattern is Powerful
# ═══════════════════════════════════════════════════════════════════════════

# Traditional Approach (Polling):
#   loop {
#     if download_finished? {
#       shutdown()
#     }
#     sleep(1000)  # Inefficient polling
#   }
#
# Event-Driven Approach (Our System):
#   register_action(evtDownloadCompleted, shutdown)
#   # Shutdown is called immediately when download completes
#   # No polling overhead
#   # More responsive
#
# BeOS-style Event System Benefits:
# 1. Decoupled - Nobody needs to know who's listening
# 2. Responsive - Actions trigger immediately
# 3. Composable - Build complex automations from simple events
# 4. Scriptable - Non-programmers can set up automations
# 5. Efficient - No polling, event-driven
# 6. Observable - Can log and monitor all system activities
# 7. Testable - Can inject events to test automations
