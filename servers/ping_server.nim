# SPDX-License-Identifier: GPL-2.0
## ping_server — demo OS service (BeOS-style named server)
##
## Registers a named mailbox "ping_server".
## Receives messages, replies by publishing a "pong" event.
##
## This is the pattern for ALL NimixOS services:
##   1. Create + register a named ServerChan (the actor's mailbox)
##   2. Announce readiness via the event server
##   3. Loop: recv message → process → reply via event_publish
##
## Currently runs as a kernel-side cooperative task.
## When ELF loading lands, this moves to ring-3 userspace unchanged.

import ../ipc/server_chan
import ../kernel/event_server
import ../kernel/traits/event
import ../core/log
import ../core/serial

const PingServerName* = "ping_server"

var pingChan*: ServerChan  ## The server's mailbox — registered at init

proc pingServerInit*() =
  ## Create and register the ping_server mailbox.
  ## Call once during kernel boot, before running the shell.
  pingChan = serverChanCreate(PingServerName)
  serverChanRegister(pingChan)
  klog(llInfo, "ping_server: mailbox registered")
  eventPublish("server.ready", PingServerName, PingServerName.len)

proc pingServerTick*() =
  ## Process one pending message (non-blocking).
  ## Call this from the main loop or scheduler tick.
  let msg = serverChanRecv(pingChan)
  if not msg.hasValue:
    return

  # Log what we received
  kprint("[ping_server] got: ")
  let dataLen = int(msg.value.len)
  for i in 0..<dataLen:
    defaultSerial.putChar(char(msg.value.data[i]))
  defaultSerial.putChar('\n')

  # Reply: publish "pong" event — any subscriber wakes up
  # Use a static cstring to avoid string allocation issues under --os:any
  let reply: cstring = "pong!"
  eventPublish("pong", cast[pointer](reply), 5)
  klog(llInfo, "ping_server: sent pong")
