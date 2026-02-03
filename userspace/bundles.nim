# SPDX-License-Identifier: GPL-2.0
## Application Bundles and Packaging
##
## BeOS-style application bundles
## Self-contained directory structure with metadata

import ../core/types

type
  # ═══════════════════════════════════════════════════════════════════════════
  # Bundle Types
  # ═══════════════════════════════════════════════════════════════════════════

  BundleType* = enum
    ## Application bundle types
    btApplication = 0               ## GUI or CLI application
    btLibrary = 1                   ## Shared library
    btAddon = 2                     ## Plugin/addon
    btServer = 3                    ## System service

  ApplicationType* = enum
    ## Application role/category
    atGeneric = 0
    atEditor = 1
    atViewer = 2
    atPlayer = 3
    atGame = 4
    atUtility = 5
    atSystem = 6

  Bundle* = object
    ## Application bundle metadata
    bundleId*: uint32
    name*: array[128, uint8]
    bundleType*: BundleType
    appType*: ApplicationType
    version*: array[32, uint8]       ## "1.0.0"
    author*: array[128, uint8]
    description*: array[512, uint8]
    icon*: array[256, uint8]         ## Path to icon
    executable*: array[256, uint8]   ## Path to executable
    signature*: array[64, uint8]     ## Unique signature
    resources*: array[256, uint8]    ## Resource directory
    documentation*: array[256, uint8] ## Help/docs path
    installPath*: array[256, uint8]  ## Where bundle is installed

  BundleInfo* = object
    ## Runtime bundle information
    bundleId*: uint32
    isLoaded*: bool
    runningAppId*: uint32            ## App ID if running
    memoryUsage*: uint64
    createdAt*: uint64

# ═══════════════════════════════════════════════════════════════════════════
# Bundle Registry
# ═══════════════════════════════════════════════════════════════════════════

const
  MaxBundles* = 512
  BundleDirectory* = "/system/apps"

var
  gBundles*: array[MaxBundles, Bundle]
  gBundleCount*: uint32 = 0
  gBundleInfo*: array[MaxBundles, BundleInfo]

# ═══════════════════════════════════════════════════════════════════════════
# Bundle Discovery and Installation
# ═══════════════════════════════════════════════════════════════════════════

proc scan_bundle_directory*(): uint32 =
  ## Scan system bundle directory and register all bundles
  ## Called during boot
  # Would scan /system/apps directory
  # Load bundle metadata from each bundle
  0

proc load_bundle_metadata*(bundlePath: cstring): Bundle =
  ## Load bundle metadata from bundle directory
  ## Expected structure:
  ##   /AppName.app/
  ##     meta.info     (metadata file)
  ##     AppName       (executable)
  ##     resources/    (images, data)
  ##     documentation/ (help files)
  result.bundleType = btApplication

proc register_bundle*(bundle: Bundle): uint32 =
  ## Register a bundle in the system
  if gBundleCount >= MaxBundles:
    return 0

  var info: BundleInfo
  info.bundleId = gBundleCount
  info.isLoaded = false

  gBundles[gBundleCount] = bundle
  gBundleInfo[gBundleCount] = info

  let id = gBundleCount
  inc gBundleCount
  return uint32(id)

# ═══════════════════════════════════════════════════════════════════════════
# Bundle Queries
# ═══════════════════════════════════════════════════════════════════════════

proc find_bundle_by_signature*(signature: cstring): uint32 =
  ## Find bundle by its signature
  ## Returns bundle ID or 0 if not found
  for i in 0..<gBundleCount:
    # Would compare signature
    return uint32(i)
  return 0

proc find_bundle_by_name*(name: cstring): uint32 =
  ## Find bundle by application name
  for i in 0..<gBundleCount:
    # Would compare name
    return uint32(i)
  return 0

proc find_bundles_by_type*(bundleType: BundleType): seq[uint32] =
  ## Find all bundles of given type
  result = @[]
  for i in 0..<gBundleCount:
    if gBundles[i].bundleType == bundleType:
      result.add(uint32(i))

proc find_bundles_for_type*(fileType: cstring): seq[uint32] =
  ## Find bundles that can handle a file type
  ## (e.g., ".txt", ".jpg")
  result = @[]
  # Would check bundle capabilities

proc get_bundle*(bundleId: uint32): ptr Bundle =
  ## Get bundle by ID
  if bundleId < gBundleCount:
    return addr gBundles[bundleId]
  return nil

proc get_bundle_info*(bundleId: uint32): ptr BundleInfo =
  ## Get bundle runtime info
  if bundleId < gBundleCount:
    return addr gBundleInfo[bundleId]
  return nil

# ═══════════════════════════════════════════════════════════════════════════
# Bundle Launching
# ═══════════════════════════════════════════════════════════════════════════

proc launch_bundle*(bundleId: uint32, args: cstring = ""): uint32 =
  ## Launch application from bundle
  ## Returns app ID or 0 on failure
  let bundle = get_bundle(bundleId)
  if bundle == nil:
    return 0

  # Would:
  # 1. Create process
  # 2. Set up memory space
  # 3. Load executable
  # 4. Initialize message port
  # 5. Start execution

  let info = get_bundle_info(bundleId)
  if info != nil:
    info.isLoaded = true

  return 1  # Placeholder - would return real app ID

proc launch_bundle_by_signature*(signature: cstring, args: cstring = ""): uint32 =
  ## Launch by signature
  let bundleId = find_bundle_by_signature(signature)
  if bundleId == 0:
    return 0
  return launch_bundle(bundleId, args)

proc launch_bundle_by_name*(name: cstring, args: cstring = ""): uint32 =
  ## Launch by application name
  let bundleId = find_bundle_by_name(name)
  if bundleId == 0:
    return 0
  return launch_bundle(bundleId, args)

# ═══════════════════════════════════════════════════════════════════════════
# Bundle Library (Shared Resources)
# ═══════════════════════════════════════════════════════════════════════════

proc load_bundle_resource*(bundleId: uint32, resourcePath: cstring): pointer =
  ## Load resource from bundle (image, data file, etc)
  nil

proc get_bundle_icon*(bundleId: uint32): pointer =
  ## Get bundle's icon
  nil

proc get_bundle_version*(bundleId: uint32): cstring =
  ## Get bundle version string
  nil

# ═══════════════════════════════════════════════════════════════════════════
# System Bundles (Pre-installed Applications)
# ═══════════════════════════════════════════════════════════════════════════

proc create_system_bundles*() =
  ## Create built-in system applications
  ## Called during kernel initialization

  # Terminal
  var terminal: Bundle
  terminal.name = "Terminal"
  terminal.bundleType = btApplication
  terminal.signature = "application/x-vnd.os-terminal"
  register_bundle(terminal)

  # File Manager
  var fileManager: Bundle
  fileManager.name = "File Manager"
  fileManager.bundleType = btApplication
  fileManager.signature = "application/x-vnd.os-filemanager"
  register_bundle(fileManager)

  # System Monitor
  var sysmon: Bundle
  sysmon.name = "System Monitor"
  sysmon.bundleType = btUtility
  sysmon.signature = "application/x-vnd.os-sysmon"
  register_bundle(sysmon)

  # Text Editor
  var textEditor: Bundle
  textEditor.name = "TextEdit"
  textEditor.bundleType = btEditor
  textEditor.signature = "application/x-vnd.os-textedit"
  register_bundle(textEditor)

  # Image Viewer
  var imageViewer: Bundle
  imageViewer.name = "ShowImage"
  imageViewer.bundleType = btViewer
  imageViewer.signature = "application/x-vnd.os-showimage"
  register_bundle(imageViewer)

# ═══════════════════════════════════════════════════════════════════════════
# Bundle Management and Queries
# ═══════════════════════════════════════════════════════════════════════════

proc list_bundles*(bundleType: BundleType = btApplication): seq[string] =
  ## List all bundles of type
  result = @[]
  for i in 0..<gBundleCount:
    if gBundles[i].bundleType == bundleType:
      result.add($gBundles[i].name)

proc get_bundle_info_string*(bundleId: uint32): string =
  ## Get formatted bundle information
  let bundle = get_bundle(bundleId)
  if bundle == nil:
    return "Bundle not found"

  var info = "Bundle: " & $bundle.name & "\n"
  info &= "Type: " & $bundle.bundleType & "\n"
  info &= "Version: " & $bundle.version & "\n"
  info &= "Author: " & $bundle.author & "\n"
  info &= "Signature: " & $bundle.signature & "\n"
  return info

proc bundle_stats*(): string =
  ## Get bundle statistics
  "Bundles: " & $gBundleCount & "/" & $MaxBundles & " installed"

proc uninstall_bundle*(bundleId: uint32): bool =
  ## Uninstall bundle (remove from registry)
  if bundleId >= gBundleCount:
    return false
  # Mark as uninstalled (could physically remove files)
  return true
