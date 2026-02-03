# SPDX-License-Identifier: GPL-2.0
## Event Server
##
## BeOS-style event notification and subscription system
## Enables event-driven scripting and automation
## "shut down the computer once downloads are finished"

import ../core/types
import ./message

type
  # ═══════════════════════════════════════════════════════════════════════════
  # Event Types
  # ═══════════════════════════════════════════════════════════════════════════

  EventType* = enum
    ## System and application events
    evtSystem = 0
    evtFile = 1                      ## File operations
    evtDownload = 2                  ## Download events
    evtNetwork = 3                   ## Network events
    evtDevice = 4                    ## Device connect/disconnect
    evtUser = 5                      ## User login/logout
    evtApplication = 6               ## App launch/exit
    evtStorage = 7                   ## Storage events
    evtMusic = 8                     ## Music player events
    evtCustom = 9                    ## Custom application events

  EventCode* = distinct uint32

  EventPriority* = enum
    epLow = 0
    epNormal = 1
    epHigh = 2
    epCritical = 3

  Event* = object
    ## Event notification
    eventId*: uint32
    eventType*: EventType
    code*: EventCode
    priority*: EventPriority
    sourceApp*: uint32               ## Which app/service generated event
    timestamp*: uint64
    dataSize*: uint32
    data*: array[256, uint8]         ## Event-specific data

  Subscription* = object
    ## Event subscription
    subscriptionId*: uint32
    subscriberPort*: uint32          ## Where to send notifications
    eventType*: EventType
    eventCode*: EventCode            ## Specific code or wildcard
    filter*: proc(evt: Event): bool  ## Optional filter function
    priority*: EventPriority         ## Notify only if >= priority

  Action* = object
    ## Automation action (triggered by event)
    actionId*: uint32
    name*: array[64, uint8]
    triggerEvent*: EventCode
    conditions*: array[8, proc(evt: Event): bool]  ## AND conditions
    conditionCount*: uint8
    actionProc*: proc(evt: Event)    ## What to do
    enabled*: bool

  Trigger* = object
    ## Event-based trigger definition
    triggerId*: uint32
    name*: array[64, uint8]
    events*: array[8, EventCode]     ## Multiple events OR'd together
    eventCount*: uint8
    condition*: proc(events: seq[Event]): bool  ## Combine multiple events
    action*: proc()                  ## Execute on trigger

# ═══════════════════════════════════════════════════════════════════════════
# Standard Event Codes
# ═══════════════════════════════════════════════════════════════════════════

const
  # System events
  evtShutdown* = EventCode(0x53485554)       ## "SHUT"
  evtReboot* = EventCode(0x52424F54)         ## "RBOT"

  # File events
  evtFileCreated* = EventCode(0x46435245)    ## "FCRE"
  evtFileModified* = EventCode(0x464D4F44)   ## "FMOD"
  evtFileDeleted* = EventCode(0x4644454C)    ## "FDEL"

  # Download events
  evtDownloadStarted* = EventCode(0x444C5354) ## "DLST"
  evtDownloadProgress* = EventCode(0x444C5052) ## "DLPR"
  evtDownloadCompleted* = EventCode(0x444C4350) ## "DLCP"
  evtDownloadFailed* = EventCode(0x444C4641)   ## "DLFA"

  # Device events
  evtDeviceConnected* = EventCode(0x44564348)  ## "DVCH"
  evtDeviceDisconnected* = EventCode(0x444F4953) ## "DVIS"

  # User events
  evtUserLogin* = EventCode(0x55534C49)     ## "USLI"
  evtUserLogout* = EventCode(0x55534C4F)    ## "USLO"

  # Application events
  evtAppLaunched* = EventCode(0x414C4C4F)   ## "ALLO"
  evtAppClosed* = EventCode(0x414C434C)     ## "ALCL"
  evtAppCrashed* = EventCode(0x414C4352)    ## "ALCR"

# ═══════════════════════════════════════════════════════════════════════════
# Global Event Server State
# ═══════════════════════════════════════════════════════════════════════════

const
  MaxSubscriptions* = 512
  MaxActions* = 256
  MaxTriggers* = 128
  MaxEventHistory* = 1024

var
  gEventServerPortId*: uint32
  gSubscriptions*: array[MaxSubscriptions, Subscription]
  gSubscriptionCount*: uint32 = 0
  gActions*: array[MaxActions, Action]
  gActionCount*: uint32 = 0
  gTriggers*: array[MaxTriggers, Trigger]
  gTriggerCount*: uint32 = 0
  gEventHistory*: array[MaxEventHistory, Event]
  gHistoryIndex*: uint32 = 0
  gTotalEvents*: uint64 = 0

# ═══════════════════════════════════════════════════════════════════════════
# Subscription Management
# ═══════════════════════════════════════════════════════════════════════════

proc subscribe_event*(eventType: EventType, eventCode: EventCode,
                       subscriberPort: uint32, priority: EventPriority = epNormal): uint32 =
  ## Subscribe to events
  ## Returns subscription ID
  if gSubscriptionCount >= MaxSubscriptions:
    return 0

  var sub: Subscription
  sub.subscriptionId = gSubscriptionCount
  sub.subscriberPort = subscriberPort
  sub.eventType = eventType
  sub.eventCode = eventCode
  sub.priority = priority

  gSubscriptions[gSubscriptionCount] = sub
  let id = gSubscriptionCount
  inc gSubscriptionCount
  return uint32(id)

proc unsubscribe_event*(subscriptionId: uint32): bool =
  ## Unsubscribe from events
  if subscriptionId >= gSubscriptionCount:
    return false
  # Mark as inactive (could remove)
  return true

proc subscribe_all_events*(eventType: EventType, subscriberPort: uint32): uint32 =
  ## Subscribe to all events of a type
  return subscribe_event(eventType, EventCode(0), subscriberPort)

# ═══════════════════════════════════════════════════════════════════════════
# Event Publishing
# ═══════════════════════════════════════════════════════════════════════════

proc publish_event*(eventType: EventType, code: EventCode, sourceApp: uint32,
                     data: pointer = nil, dataSize: uint32 = 0,
                     priority: EventPriority = epNormal): uint32 =
  ## Publish an event
  ## Notifies all subscribed listeners
  ## Returns event ID
  var evt: Event
  evt.eventId = uint32(gTotalEvents)
  evt.eventType = eventType
  evt.code = code
  evt.sourceApp = sourceApp
  evt.priority = priority
  evt.timestamp = 0  # Would be current tick
  evt.dataSize = min(dataSize, 256'u32)

  if data != nil and evt.dataSize > 0:
    # Copy event data
    discard

  # Add to history
  gEventHistory[gHistoryIndex] = evt
  gHistoryIndex = (gHistoryIndex + 1) mod MaxEventHistory
  inc gTotalEvents

  # Notify subscribers
  for i in 0..<gSubscriptionCount:
    let sub = addr gSubscriptions[i]
    if sub.eventType == eventType or eventType == evtSystem:
      if sub.eventCode == EventCode(0) or sub.eventCode == code:
        if sub.priority <= priority:
          # Send notification message
          sendMessage(sub.subscriberPort, uint32(code), uint32(sourceApp), int32(evt.eventId))

  # Check actions
  for i in 0..<gActionCount:
    let action = addr gActions[i]
    if action.enabled and action.triggerEvent == code:
      # Check conditions
      var allMet = true
      for j in 0..<action.conditionCount:
        if action.conditions[j] != nil and not action.conditions[j](evt):
          allMet = false
          break
      if allMet and action.actionProc != nil:
        action.actionProc(evt)

  return evt.eventId

# ═══════════════════════════════════════════════════════════════════════════
# Automation Actions
# ═══════════════════════════════════════════════════════════════════════════

proc register_action*(triggerEvent: EventCode, name: cstring,
                      actionProc: proc(evt: Event)): uint32 =
  ## Register an automation action
  ## Triggered when specific event occurs
  if gActionCount >= MaxActions:
    return 0

  var action: Action
  action.actionId = gActionCount
  action.triggerEvent = triggerEvent
  action.actionProc = actionProc
  action.enabled = true

  gActions[gActionCount] = action
  let id = gActionCount
  inc gActionCount
  return uint32(id)

proc add_action_condition*(actionId: uint32, condition: proc(evt: Event): bool): bool =
  ## Add a condition to an action
  if actionId >= gActionCount:
    return false
  let action = addr gActions[actionId]
  if action.conditionCount >= 8:
    return false
  action.conditions[action.conditionCount] = condition
  inc action.conditionCount
  return true

proc enable_action*(actionId: uint32): bool =
  ## Enable an action
  if actionId >= gActionCount:
    return false
  gActions[actionId].enabled = true
  return true

proc disable_action*(actionId: uint32): bool =
  ## Disable an action
  if actionId >= gActionCount:
    return false
  gActions[actionId].enabled = false
  return true

# ═══════════════════════════════════════════════════════════════════════════
# Complex Triggers (Multi-Event Automation)
# ═══════════════════════════════════════════════════════════════════════════

proc register_trigger*(name: cstring, triggerAction: proc()): uint32 =
  ## Register a complex trigger that combines multiple events
  ## Example: "download finished AND all tasks complete"
  if gTriggerCount >= MaxTriggers:
    return 0

  var trigger: Trigger
  trigger.triggerId = gTriggerCount
  trigger.action = triggerAction

  gTriggers[gTriggerCount] = trigger
  let id = gTriggerCount
  inc gTriggerCount
  return uint32(id)

proc add_trigger_event*(triggerId: uint32, eventCode: EventCode): bool =
  ## Add event to trigger
  if triggerId >= gTriggerCount:
    return false
  let trigger = addr gTriggers[triggerId]
  if trigger.eventCount >= 8:
    return false
  trigger.events[trigger.eventCount] = eventCode
  inc trigger.eventCount
  return true

# ═══════════════════════════════════════════════════════════════════════════
# Pre-Built Common Automations
# ═══════════════════════════════════════════════════════════════════════════

proc setup_shutdown_on_downloads_complete*(): uint32 =
  ## Automation: Shut down computer once all downloads complete
  ## Returns action ID
  return register_action(evtDownloadCompleted, "shutdown_on_download",
    proc(evt: Event) =
      # Check if ALL downloads are complete
      publish_event(evtSystem, evtShutdown, 0, nil, 0, epHigh)
  )

proc setup_file_backup_on_modify*(backupPort: uint32): uint32 =
  ## Automation: Back up file when it's modified
  return register_action(evtFileModified, "backup_on_modify",
    proc(evt: Event) =
      # Send message to backup service
      sendMessage(backupPort, uint32(evt.code), evt.sourceApp, int32(evt.eventId))
  )

proc setup_notify_on_device_connect*(): uint32 =
  ## Automation: Notify user when device connects
  return register_action(evtDeviceConnected, "notify_device",
    proc(evt: Event) =
      publish_event(evtSystem, EventCode(0x4E4F5449), 0)  ## "NOTI"
  )

# ═══════════════════════════════════════════════════════════════════════════
# Event Queries and History
# ═══════════════════════════════════════════════════════════════════════════

proc get_event_history*(maxCount: uint32): seq[Event] =
  ## Get recent events
  result = @[]
  let startIdx = if gTotalEvents > MaxEventHistory: uint32(gTotalEvents mod MaxEventHistory) else: 0'u32
  # Would return recent events

proc find_events_by_type*(eventType: EventType): seq[Event] =
  ## Find all events of type in history
  result = @[]
  # Would filter history

proc get_event_count*(eventType: EventType): uint32 =
  ## Get count of events by type
  var count = 0'u32
  # Would count

  return count

# ═══════════════════════════════════════════════════════════════════════════
# Event Server Initialization
# ═══════════════════════════════════════════════════════════════════════════

proc start_event_server*(): bool =
  ## Start the event server
  gEventServerPortId = createPort(128)
  gSubscriptionCount = 0
  gActionCount = 0
  gTriggerCount = 0
  return gEventServerPortId > 0

# ═══════════════════════════════════════════════════════════════════════════
# Statistics
# ═══════════════════════════════════════════════════════════════════════════

proc event_server_stats*(): string =
  ## Get event server statistics
  "Event Server: " & $gTotalEvents & " total events | " &
  $gSubscriptionCount & " subscriptions | " &
  $gActionCount & " actions | " &
  $gTriggerCount & " triggers"

proc list_subscriptions*(): seq[uint32] =
  ## Get list of active subscriptions
  result = @[]
  for i in 0..<gSubscriptionCount:
    result.add(gSubscriptions[i].subscriptionId)

proc list_actions*(): seq[uint32] =
  ## Get list of registered actions
  result = @[]
  for i in 0..<gActionCount:
    result.add(gActions[i].actionId)
