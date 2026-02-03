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
# Application Lifecycle - Forth-style: helpers then high-level operations
# ═══════════════════════════════════════════════════════════════════════════

proc app_validate(appId: uint32): bool =
  ## Check if application ID is valid
  # Strategy: Bounds check
  return appId < gAppCount

proc app_get(appId: uint32): ptr Application =
  ## Get application by ID
  # Strategy: Index array if valid
  if not app_validate(appId):
    return nil
  return addr gApplications[appId]

proc string_to_app_name(src: cstring): array[64, uint8] =
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

proc be_app_create*(name: cstring, signature: ApplicationSignature): uint32 =
  ## Create new application (like BApplication in BeOS)
  # Strategy: Allocate application slot, create port and looper
  if gAppCount >= MaxApplications:
    return 0

  var app: Application
  app.looperId = createLooper(name)
  if app.looperId == 0:
    return 0

  app.mainPortId = createPort(DefaultPortCapacity, name)
  if app.mainPortId == 0:
    return 0

  app.name = string_to_app_name(name)
  app.pid = 0  # Would be current process
  app.signature = signature
  app.flags = ApplicationFlags(0)
  app.isActive = false
  app.isQuitting = false

  gApplications[gAppCount] = app
  let id = gAppCount
  inc gAppCount
  return uint32(id)

proc be_app_start*(appId: uint32): bool =
  ## Start application main loop (async)
  # Strategy: Mark active and start looper thread
  let app = app_get(appId)
  if app == nil:
    return false

  app.isActive = true
  gActiveApp = appId
  return startLooper(app.looperId)

proc be_app_quit*(appId: uint32): bool =
  ## Mark application for quitting
  # Strategy: Set quit flag, send quit message to looper
  let app = app_get(appId)
  if app == nil:
    return false

  app.isQuitting = true
  return stopLooper(app.looperId)

proc be_app_is_running*(appId: uint32): bool =
  ## Check if application is running
  # Strategy: Active and not quitting
  let app = app_get(appId)
  if app == nil:
    return false
  return app.isActive and not app.isQuitting

proc be_app_get_port*(appId: uint32): uint32 =
  ## Get application's main port
  # Strategy: Look up port from app struct
  let app = app_get(appId)
  if app == nil:
    return 0
  return app.mainPortId

proc be_app_post_message*(appId: uint32, msg: ptr Message): bool =
  ## Send message to application
  # Strategy: Post to application's port
  let app = app_get(appId)
  if app == nil:
    return false
  return sendMessage(app.mainPortId, msg)

proc be_app_get_looper*(appId: uint32): uint32 =
  ## Get application's message looper
  # Strategy: Return looper ID
  let app = app_get(appId)
  if app == nil:
    return 0
  return app.looperId

# ═══════════════════════════════════════════════════════════════════════════
# Window Management - Forth-style: validation then operations
# ═══════════════════════════════════════════════════════════════════════════

proc window_validate(windowId: uint32): bool =
  ## Check if window ID is valid
  # Strategy: Bounds check
  return windowId < gWindowCount

proc window_get(windowId: uint32): ptr Window =
  ## Get window by ID
  # Strategy: Index array if valid
  if not window_validate(windowId):
    return nil
  return addr gWindows[windowId]

proc string_to_title(src: cstring): array[128, uint8] =
  ## Convert cstring to fixed-size title
  # Strategy: Copy until null or 128 bytes
  var result: array[128, uint8]
  if src != nil:
    var i = 0
    while i < 127:
      let byte = cast[ptr uint8](cast[uint64](src) + i)[]
      if byte == 0:
        break
      result[i] = byte
      i += 1
    result[i] = 0
  return result

proc be_window_create*(appId: uint32, title: cstring): uint32 =
  ## Create window in application
  # Strategy: Allocate window, create looper and port, associate with app
  if gWindowCount >= MaxWindows or not app_validate(appId):
    return 0

  var window: Window
  window.appId = appId
  window.looperId = createLooper()
  if window.looperId == 0:
    return 0

  window.portId = createPort(DefaultPortCapacity, title)
  if window.portId == 0:
    return 0

  window.title = string_to_title(title)
  window.flags = 0
  window.isHidden = true
  window.isMinimized = false
  window.isMaximized = false

  gWindows[gWindowCount] = window
  let id = gWindowCount
  inc gWindowCount
  return uint32(id)

proc be_window_show*(windowId: uint32): bool =
  ## Show window on screen
  # Strategy: Clear hidden flag, start looper
  let window = window_get(windowId)
  if window == nil:
    return false

  window.isHidden = false
  return startLooper(window.looperId)

proc be_window_hide*(windowId: uint32): bool =
  ## Hide window (but keep looper running)
  # Strategy: Set hidden flag
  let window = window_get(windowId)
  if window == nil:
    return false

  window.isHidden = true
  return true

proc be_window_minimize*(windowId: uint32): bool =
  ## Minimize window
  # Strategy: Set minimized flag
  let window = window_get(windowId)
  if window == nil:
    return false

  window.isMinimized = true
  window.isHidden = true
  return true

proc be_window_maximize*(windowId: uint32): bool =
  ## Maximize window
  # Strategy: Set maximized flag, clear minimized
  let window = window_get(windowId)
  if window == nil:
    return false

  window.isMaximized = true
  window.isMinimized = false
  window.isHidden = false
  return true

proc be_window_set_title*(windowId: uint32, title: cstring): bool =
  ## Change window title
  # Strategy: Update title field
  let window = window_get(windowId)
  if window == nil:
    return false

  window.title = string_to_title(title)
  return true

proc be_window_get_port*(windowId: uint32): uint32 =
  ## Get window's message port
  # Strategy: Return port from window struct
  let window = window_get(windowId)
  if window == nil:
    return 0
  return window.portId

proc be_window_get_looper*(windowId: uint32): uint32 =
  ## Get window's message looper
  # Strategy: Return looper from window struct
  let window = window_get(windowId)
  if window == nil:
    return 0
  return window.looperId

proc be_window_post_message*(windowId: uint32, msg: ptr Message): bool =
  ## Send message to window
  # Strategy: Post to window's port
  let window = window_get(windowId)
  if window == nil:
    return false
  return sendMessage(window.portId, msg)

# ═══════════════════════════════════════════════════════════════════════════
# View Management - Drawing surface hierarchy within windows
# ═══════════════════════════════════════════════════════════════════════════

proc view_validate(viewId: uint32): bool =
  ## Check if view ID is valid
  # Strategy: Bounds check
  return viewId < gViewCount

proc view_get(viewId: uint32): ptr View =
  ## Get view by ID
  # Strategy: Index array if valid
  if not view_validate(viewId):
    return nil
  return addr gViews[viewId]

proc string_to_view_name(src: cstring): array[64, uint8] =
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

proc be_view_create*(windowId: uint32, name: cstring, x: int32, y: int32,
                     width: int32, height: int32): uint32 =
  ## Create view (drawing area) in window
  # Strategy: Allocate view, associate with window, set bounds
  if gViewCount >= MaxViews or not window_validate(windowId):
    return 0

  var view: View
  view.windowId = windowId
  view.name = string_to_view_name(name)
  view.x = x
  view.y = y
  view.width = width
  view.height = height
  view.isHidden = false

  gViews[gViewCount] = view
  let id = gViewCount
  inc gViewCount
  return uint32(id)

proc view_point_in_bounds(view: ptr View, x: int32, y: int32): bool =
  ## Check if point is within view bounds
  # Strategy: Range check x and y
  return x >= view.x and x < view.x + view.width and
         y >= view.y and y < view.y + view.height

proc view_clip_rect(view: ptr View, x: int32, y: int32, w: int32, h: int32): tuple[x1, y1, x2, y2: int32] =
  ## Clip rectangle to view bounds
  # Strategy: Compute intersection with view bounds
  let x1 = if x < view.x: view.x else: x
  let y1 = if y < view.y: view.y else: y
  let x2 = if x + w > view.x + view.width: view.x + view.width else: x + w
  let y2 = if y + h > view.y + view.height: view.y + view.height else: y + h
  return (x1, y1, x2, y2)

proc be_view_draw_string*(viewId: uint32, x: int32, y: int32, text: cstring): bool =
  ## Draw text string in view
  # Strategy: Validate view, check bounds, record draw command
  # {.warning: "TODO: Implement actual text rendering to framebuffer".}
  let view = view_get(viewId)
  if view == nil or view.isHidden:
    return false

  if not view_point_in_bounds(view, x, y):
    return false

  # In real implementation: would send draw command to app_server
  # which manages framebuffer/video hardware
  return true

proc be_view_draw_rect*(viewId: uint32, x: int32, y: int32, w: int32, h: int32): bool =
  ## Draw rectangle outline in view
  # Strategy: Validate view, clip to bounds, record draw
  # {.warning: "TODO: Implement actual rect rendering to framebuffer".}
  let view = view_get(viewId)
  if view == nil or view.isHidden:
    return false

  # Clip rectangle to view bounds
  let (x1, y1, x2, y2) = view_clip_rect(view, x, y, w, h)
  if x2 <= x1 or y2 <= y1:
    return false

  # In real implementation: would send draw command to app_server
  return true

proc be_view_fill_rect*(viewId: uint32, x: int32, y: int32, w: int32, h: int32): bool =
  ## Draw filled rectangle
  # Strategy: Validate view, clip to bounds, fill region
  # {.warning: "TODO: Implement actual filled rect rendering to framebuffer".}
  let view = view_get(viewId)
  if view == nil or view.isHidden:
    return false

  # Clip rectangle to view bounds
  let (x1, y1, x2, y2) = view_clip_rect(view, x, y, w, h)
  if x2 <= x1 or y2 <= y1:
    return false

  # In real implementation: would send fill command to app_server
  return true

proc be_view_invalidate*(viewId: uint32): bool =
  ## Mark view for redraw
  # Strategy: Mark as needing redraw (app_server will see it)
  let view = view_get(viewId)
  if view == nil:
    return false

  # In real implementation: would queue redraw request
  return true

proc be_view_hide*(viewId: uint32): bool =
  ## Hide view
  # Strategy: Set hidden flag
  let view = view_get(viewId)
  if view == nil:
    return false

  view.isHidden = true
  return true

proc be_view_show*(viewId: uint32): bool =
  ## Show view
  # Strategy: Clear hidden flag
  let view = view_get(viewId)
  if view == nil:
    return false

  view.isHidden = false
  return true

# ═══════════════════════════════════════════════════════════════════════════
# Standard Message Handlers - Builtin message processing
# ═══════════════════════════════════════════════════════════════════════════

proc app_message_quit*(appId: uint32) =
  ## Handle quit message
  # Strategy: Mark app as quitting
  let app = app_get(appId)
  if app != nil:
    app.isQuitting = true

proc app_message_ready*(appId: uint32) =
  ## Handle ready message (app initialized)
  # Strategy: Mark app as active
  let app = app_get(appId)
  if app != nil:
    app.isActive = true

proc window_message_close*(windowId: uint32) =
  ## Handle window close request
  # Strategy: Mark window as needing close
  # {.warning: "TODO: Implement window close handshake with app".}
  let window = window_get(windowId)
  if window != nil:
    window.isHidden = true

# ═══════════════════════════════════════════════════════════════════════════
# Introspection and Statistics - Monitoring and debugging
# ═══════════════════════════════════════════════════════════════════════════

proc count_app_windows*(appId: uint32): uint32 =
  ## Count windows belonging to app
  # Strategy: Iterate windows, count matches
  var count = 0'u32
  if not app_validate(appId):
    return 0

  for i in 0..<gWindowCount:
    if gWindows[i].appId == appId:
      inc count
  return count

proc count_window_views*(windowId: uint32): uint32 =
  ## Count views in window
  # Strategy: Iterate views, count matches
  var count = 0'u32
  if not window_validate(windowId):
    return 0

  for i in 0..<gViewCount:
    if gViews[i].windowId == windowId:
      inc count
  return count

proc be_app_stats*(): string =
  ## Get application statistics
  # Strategy: Format resource usage
  "Applications: " & $gAppCount & "/" & $MaxApplications &
  " | Windows: " & $gWindowCount & "/" & $MaxWindows &
  " | Views: " & $gViewCount & "/" & $MaxViews

proc be_app_info*(appId: uint32): string =
  ## Get application info
  # Strategy: Look up app, format status
  let app = app_get(appId)
  if app == nil:
    return "Application not found"

  let status = if app.isActive: "running" else: "stopped"
  let winCount = count_app_windows(appId)
  return "App " & $appId & ": " & status & " [" & $winCount & " windows]"

proc listApplications*(): string =
  ## List all applications
  # Strategy: Iterate apps, format output
  var result = "Active Applications:\n"
  for i in 0..<gAppCount:
    let app = addr gApplications[i]
    let status = if app.isActive: "RUN" else: "STP"
    result = result & "  App " & $i & ": [" & status & "]\n"
  return result

proc listWindowsInApp*(appId: uint32): string =
  ## List windows of application
  # Strategy: Iterate windows, show those matching app
  var result = "Windows in App " & $appId & ":\n"
  if not app_validate(appId):
    return result

  for i in 0..<gWindowCount:
    if gWindows[i].appId == appId:
      let hidden = if gWindows[i].isHidden: "H" else: "V"
      result = result & "  Window " & $i & ": [" & hidden & "]\n"
  return result

proc getWindowStats*(windowId: uint32): string =
  ## Get window statistics
  # Strategy: Look up window, show counts
  let window = window_get(windowId)
  if window == nil:
    return "Window not found"

  let viewCount = count_window_views(windowId)
  return "Window " & $windowId & ": " & $viewCount & " views"
