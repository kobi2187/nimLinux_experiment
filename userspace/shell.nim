# SPDX-License-Identifier: GPL-2.0
## BeOS-Style Command Shell
##
## Interactive shell for command execution
## Integrates with the message-based application framework

import ../core/types
import ./message
import ./app
import ./services

type
  # ═══════════════════════════════════════════════════════════════════════════
  # Shell Types
  # ═══════════════════════════════════════════════════════════════════════════

  CommandCode* = enum
    ## Built-in shell commands
    cmdHelp = 0
    cmdQuit = 1
    cmdClear = 2
    cmdEcho = 3
    cmdPs = 4                       ## Process/app listing
    cmdKill = 5                     ## Kill application
    cmdLs = 6                       ## List files
    cmdCd = 7                       ## Change directory
    cmdPwd = 8                      ## Print working directory
    cmdCat = 9                      ## Print file contents
    cmdMkdir = 10
    cmdRm = 11                      ## Remove file
    cmdMv = 12                      ## Move file
    cmdCp = 13                      ## Copy file
    cmdWho = 14                     ## List users
    cmdDate = 15                    ## Print date/time
    cmdTop = 16                     ## Process monitor
    cmdUname = 17                   ## System info
    cmdService = 18                 ## Service management
    cmdLaunch = 19                  ## Launch application
    cmdHalt = 20                    ## Shutdown

  Command* = object
    ## Parsed shell command
    code*: CommandCode
    name*: array[64, uint8]
    args*: array[32, array[256, uint8]]
    argCount*: uint8

  Shell* = object
    ## Interactive shell session
    shellId*: uint32
    isRunning*: bool
    currentDir*: array[256, uint8]
    commandHistory*: array[256, array[256, uint8]]
    historyCount*: uint16
    portId*: uint32

# ═══════════════════════════════════════════════════════════════════════════
# Global Shell State
# ═══════════════════════════════════════════════════════════════════════════

const
  MaxShells* = 8

var
  gShells*: array[MaxShells, Shell]
  gShellCount*: uint32 = 0

# ═══════════════════════════════════════════════════════════════════════════
# Shell Lifecycle
# ═══════════════════════════════════════════════════════════════════════════

proc shell_create*(): uint32 =
  ## Create new shell session
  if gShellCount >= MaxShells:
    return 0

  var shell: Shell
  shell.shellId = gShellCount
  shell.isRunning = true
  shell.portId = createPort()
  shell.historyCount = 0

  gShells[gShellCount] = shell
  let id = gShellCount
  inc gShellCount
  return uint32(id)

proc shell_quit*(shellId: uint32): bool =
  ## Close shell session
  if shellId >= gShellCount:
    return false
  gShells[shellId].isRunning = false
  return true

# ═══════════════════════════════════════════════════════════════════════════
# Command Parsing and Execution
# ═══════════════════════════════════════════════════════════════════════════

proc shell_parse_command*(input: cstring): Command =
  ## Parse command line into Command structure
  result.code = cmdHelp
  result.argCount = 0
  # Would tokenize input string

proc shell_execute_help*(): string =
  ## Help/usage information
  var help = "BeOS Shell - Available Commands:\n"
  help &= "help                - Show this help\n"
  help &= "quit/exit           - Exit shell\n"
  help &= "echo [text]         - Print text\n"
  help &= "ps                  - List running applications\n"
  help &= "launch [app]        - Launch application\n"
  help &= "kill [pid]          - Terminate application\n"
  help &= "ls [dir]            - List files\n"
  help &= "pwd                 - Print working directory\n"
  help &= "cd [dir]            - Change directory\n"
  help &= "cat [file]          - Print file contents\n"
  help &= "mkdir [dir]         - Create directory\n"
  help &= "rm [file]           - Remove file\n"
  help &= "date                - Print date and time\n"
  help &= "uname               - Print system info\n"
  help &= "top                 - Show process monitor\n"
  help &= "service             - Manage services\n"
  help &= "halt                - Shutdown system\n"
  return help

proc shell_execute_ps*(): string =
  ## List running applications
  var result = "Running Applications:\n"
  result &= "PID    Name              Status\n"
  result &= "----- --------------- -------\n"
  # Would iterate through applications
  return result

proc shell_execute_echo*(args: ptr array[32, array[256, uint8]], argCount: uint8): string =
  ## Echo command
  if argCount > 0:
    return $args[0]
  return ""

proc shell_execute_date*(): string =
  ## Print current date and time
  # Would get from timer system
  return "2026-02-03 12:00:00 UTC"

proc shell_execute_uname*(): string =
  ## Print system information
  var result = "System: NimixOS\n"
  result &= "Kernel: 0.2.0-alpha\n"
  result &= "Arch: x86_64\n"
  result &= "CPU Count: 4\n"
  return result

proc shell_execute_top*(): string =
  ## Process monitor
  var result = "Top - Press 'q' to quit\n"
  result &= "PID    App Name         CPU%   Memory\n"
  result &= "----- --------------- ------ -------\n"
  # Would show live process/application stats
  return result

proc shell_execute_service*(command: cstring): string =
  ## Service management
  # Would parse subcommands: list, start, stop, restart, status
  return services_stats()

proc shell_execute_ls*(path: cstring): string =
  ## List directory
  var result = "Files in " & $path & ":\n"
  # Would query storage server
  return result

proc shell_execute_pwd*(): string =
  ## Print working directory
  return "/home/user"

proc shell_execute_mkdir*(path: cstring): string =
  ## Create directory
  return "Directory created: " & $path

proc shell_execute_rm*(path: cstring): string =
  ## Remove file
  return "Removed: " & $path

proc shell_execute_cat*(path: cstring): string =
  ## Print file contents
  return "File contents of " & $path & ":\n[File data would be here]"

proc shell_execute_launch*(appName: cstring): string =
  ## Launch application
  let appId = be_app_create(appName, appTypeTool)
  if appId == 0:
    return "Failed to launch: " & $appName
  if not be_app_start(appId):
    return "Failed to start application"
  return "Launched: " & $appName & " (App " & $appId & ")"

proc shell_execute_kill*(pidStr: cstring): string =
  ## Kill application
  # Would parse PID and terminate
  return "Killed process"

proc shell_execute_halt*(): string =
  ## Shutdown system
  return "System shutting down..."

# ═══════════════════════════════════════════════════════════════════════════
# Shell REPL
# ═══════════════════════════════════════════════════════════════════════════

proc shell_execute_command*(shellId: uint32, command: Command): string =
  ## Execute a parsed command and return output
  case command.code
  of cmdHelp:
    return shell_execute_help()
  of cmdQuit:
    shell_quit(shellId)
    return "Goodbye!"
  of cmdEcho:
    return shell_execute_echo(addr command.args, command.argCount)
  of cmdPs:
    return shell_execute_ps()
  of cmdDate:
    return shell_execute_date()
  of cmdUname:
    return shell_execute_uname()
  of cmdTop:
    return shell_execute_top()
  of cmdService:
    return shell_execute_service("list")
  of cmdPwd:
    return shell_execute_pwd()
  of cmdLs:
    return shell_execute_ls(".")
  of cmdCd:
    return "Changed directory"
  of cmdLaunch:
    return shell_execute_launch("app")
  of cmdKill:
    return shell_execute_kill("0")
  of cmdHalt:
    return shell_execute_halt()
  else:
    return "Unknown command"

proc shell_main_loop*(shellId: uint32) =
  ## Main shell interaction loop
  if shellId >= gShellCount:
    return

  let shell = addr gShells[shellId]

  while shell.isRunning:
    # Would print prompt and wait for input
    # Parse and execute command
    # Display output
    # Store in history
    discard

# ═══════════════════════════════════════════════════════════════════════════
# Shell Statistics and Info
# ═══════════════════════════════════════════════════════════════════════════

proc shell_get_info*(shellId: uint32): string =
  ## Get shell session info
  if shellId >= gShellCount:
    return "Shell not found"
  let shell = addr gShells[shellId]
  let status = if shell.isRunning: "active" else: "closed"
  return "Shell " & $shellId & ": " & status &
         " | History: " & $shell.historyCount & " commands"

proc shell_stats*(): string =
  ## Get shell statistics
  "Shells: " & $gShellCount & "/" & $MaxShells & " active"
