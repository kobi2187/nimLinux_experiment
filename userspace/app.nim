# SPDX-License-Identifier: GPL-2.0
## BeOS-Style Application Framework
##
## BApplication equivalent - main entry point for GUI/CLI applications
## Every app is multithreaded and message-driven by design

import ../core/types
import ./message

type
  # ═══════════════════════════════════════════════════════════════════════════
  # Application Types
  # ═══════════════════════════════════════════════════════════════════════════

  ApplicationSignature* = enum
    ## Application role/signature
    appTypeGUI = 0                  ## GUI application (has windows)
    appTypeCLI = 1                  ## Command-line application
    appTypeService = 2              ## Background service/daemon
    appTypeTool = 3                 ## System tool/utility

  ApplicationFlags* = distinct uint32

  Application* = object
    ## BeOS-style BApplication
    name*: array[64, uint8]
    signature*: ApplicationSignature
    flags*: ApplicationFlags
    pid*: uint32
    looperId*: uint32               ## Message looper
    mainPortId*: uint32             ## Application port
    isActive*: bool
    isQuitting*: bool

  Window* = object
    ## BeOS-style BWindow
    title*: array[128, uint8]
    windowId*: uint32
    appId*: uint32
    looperId*: uint32
    portId*: uint32
    flags*: uint32
    isHidden*: bool
    isMinimized*: bool
    isMaximized*: bool

  View* = object
    ## BeOS-style BView (drawing surface)
    name*: array[64, uint8]
    viewId*: uint32
    windowId*: uint32
    x*, y*: int32
    width*, height*: int32
    isHidden*: bool

# ═══════════════════════════════════════════════════════════════════════════
# Global Application State
# ═══════════════════════════════════════════════════════════════════════════

const
  MaxApplications* = 256
  MaxWindows* = 1024
  MaxViews* = 8192

var
  gApplications*: array[MaxApplications, Application]
  gAppCount*: uint32 = 0
  gActiveApp*: uint32 = 0           ## Currently active application
  gWindows*: array[MaxWindows, Window]
  gWindowCount*: uint32 = 0
  gViews*: array[MaxViews, View]
  gViewCount*: uint32 = 0

# ═══════════════════════════════════════════════════════════════════════════
# Application Lifecycle
# ═══════════════════════════════════════════════════════════════════════════

proc be_app_create*(name: cstring, signature: ApplicationSignature): uint32 =
  ## Create new application (like instantiating BApplication)
  ## Returns app ID
  if gAppCount >= MaxApplications:
    return 0

  var app: Application
  app.looperId = createLooper(name)
  app.mainPortId = createPort()
  app.pid = 0  # Would be current process
  app.signature = signature
  app.isActive = false
  app.isQuitting = false

  gApplications[gAppCount] = app
  let id = gAppCount
  inc gAppCount
  return uint32(id)

proc be_app_start*(appId: uint32): bool =
  ## Start application main loop
  if appId >= gAppCount:
    return false
  gApplications[appId].isActive = true
  gActiveApp = appId
  return startLooper(gApplications[appId].looperId)

proc be_app_quit*(appId: uint32): bool =
  ## Mark application for quitting
  if appId >= gAppCount:
    return false
  gApplications[appId].isQuitting = true
  # Send quit message to looper
  return true

proc be_app_is_running*(appId: uint32): bool =
  ## Check if application is running
  if appId >= gAppCount:
    return false
  return gApplications[appId].isActive and not gApplications[appId].isQuitting

proc be_app_get_port*(appId: uint32): uint32 =
  ## Get application's main port
  if appId >= gAppCount:
    return 0
  return gApplications[appId].mainPortId

# ═══════════════════════════════════════════════════════════════════════════
# Window Management
# ═══════════════════════════════════════════════════════════════════════════

proc be_window_create*(appId: uint32, title: cstring): uint32 =
  ## Create window in application
  if gWindowCount >= MaxWindows:
    return 0

  var window: Window
  window.appId = appId
  window.looperId = createLooper()
  window.portId = createPort()
  window.flags = 0

  gWindows[gWindowCount] = window
  let id = gWindowCount
  inc gWindowCount
  return uint32(id)

proc be_window_show*(windowId: uint32): bool =
  ## Show window on screen
  if windowId >= gWindowCount:
    return false
  gWindows[windowId].isHidden = false
  return true

proc be_window_hide*(windowId: uint32): bool =
  ## Hide window
  if windowId >= gWindowCount:
    return false
  gWindows[windowId].isHidden = true
  return true

proc be_window_set_title*(windowId: uint32, title: cstring): bool =
  ## Change window title
  if windowId >= gWindowCount:
    return false
  return true

proc be_window_get_port*(windowId: uint32): uint32 =
  ## Get window's message port
  if windowId >= gWindowCount:
    return 0
  return gWindows[windowId].portId

# ═══════════════════════════════════════════════════════════════════════════
# View Management
# ═══════════════════════════════════════════════════════════════════════════

proc be_view_create*(windowId: uint32, name: cstring, x: int32, y: int32,
                     width: int32, height: int32): uint32 =
  ## Create view (drawing area) in window
  if gViewCount >= MaxViews:
    return 0

  var view: View
  view.windowId = windowId
  view.x = x
  view.y = y
  view.width = width
  view.height = height

  gViews[gViewCount] = view
  let id = gViewCount
  inc gViewCount
  return uint32(id)

proc be_view_draw_string*(viewId: uint32, x: int32, y: int32, text: cstring): bool =
  ## Draw text string in view
  if viewId >= gViewCount:
    return false
  # Would render text to view
  return true

proc be_view_draw_rect*(viewId: uint32, x: int32, y: int32, w: int32, h: int32): bool =
  ## Draw rectangle in view
  if viewId >= gViewCount:
    return false
  return true

proc be_view_fill_rect*(viewId: uint32, x: int32, y: int32, w: int32, h: int32): bool =
  ## Draw filled rectangle
  if viewId >= gViewCount:
    return false
  return true

# ═══════════════════════════════════════════════════════════════════════════
# Standard Message Handlers
# ═══════════════════════════════════════════════════════════════════════════

proc app_message_quit*(appId: uint32) =
  ## Handle quit message
  let app = addr gApplications[appId]
  app.isQuitting = true

proc app_message_ready*(appId: uint32) =
  ## Handle ready message (app initialized)
  let app = addr gApplications[appId]
  app.isActive = true

# ═══════════════════════════════════════════════════════════════════════════
# Statistics
# ═══════════════════════════════════════════════════════════════════════════

proc be_app_stats*(): string =
  ## Get application statistics
  "Applications: " & $gAppCount & "/" & $MaxApplications &
  " | Windows: " & $gWindowCount & "/" & $MaxWindows &
  " | Views: " & $gViewCount & "/" & $MaxViews

proc be_app_info*(appId: uint32): string =
  ## Get application info
  if appId >= gAppCount:
    return "Application not found"
  let app = addr gApplications[appId]
  let status = if app.isActive: "running" else: "stopped"
  "App " & $appId & ": " & status
