# SPDX-License-Identifier: GPL-2.0
## Server Channel — named MPSC ring-buffer mailbox for ELF servers
##
## An ELF server creates a ServerChan, registers it by name, then calls
## serverChanRecv() in its message loop. Any tier sends via serverChanPost().
##
## Backed by a simple ring buffer — lock-free for single-CPU use.
## When SMP is added, a spinlock will protect head/tail.
##
## Kernel-safe: no stdlib imports. Uses a custom Option type so this module
## compiles under --os:any (no std/options available there).

const
  ServerChanDepth*   = 16    ## Ring buffer depth (power of 2)
  ServerMsgMaxLen*   = 256   ## Max payload bytes per message
  ServerChanNameLen* = 64    ## Max channel name length
  MaxServerChans*    = 32    ## Max registered channels

type
  ServerMsg* = object
    len*:  uint16
    data*: array[ServerMsgMaxLen, byte]

  ServerChan* = object
    name*: array[ServerChanNameLen, char]
    buf:   array[ServerChanDepth, ServerMsg]
    head:  int
    tail:  int
    count: int

  ## Minimal Option type — avoids std/options dependency under --os:any.
  MaybeMsg* = object
    hasValue*: bool
    value*:    ServerMsg

var
  registry:      array[MaxServerChans, ptr ServerChan]
  registryCount: int = 0

proc serverChanRegistryInit*() =
  ## Reset the global channel registry (call once at kernel init or in tests).
  registryCount = 0
  for i in 0..<MaxServerChans: registry[i] = nil

proc fillName(dst: var array[ServerChanNameLen, char], src: string) =
  let lim = if src.len < ServerChanNameLen - 1: src.len else: ServerChanNameLen - 1
  for i in 0..<lim:
    dst[i] = src[i]
  dst[lim] = '\0'

proc serverChanCreate*(name: string): ServerChan =
  ## Allocate and initialise a channel with the given name.
  result.head  = 0
  result.tail  = 0
  result.count = 0
  fillName(result.name, name)

proc serverChanName*(ch: ServerChan): string =
  ## Return the channel name as a Nim string (for tests / logging).
  var s = ""
  for c in ch.name:
    if c == '\0': break
    s.add(c)
  s

proc serverChanPost*(ch: var ServerChan, msg: ServerMsg): bool =
  ## Enqueue a message. Returns false if the ring buffer is full.
  if ch.count >= ServerChanDepth: return false
  ch.buf[ch.tail] = msg
  ch.tail = (ch.tail + 1) mod ServerChanDepth
  inc ch.count
  true

proc serverChanRecv*(ch: var ServerChan): MaybeMsg =
  ## Dequeue the oldest message. Returns hasValue=false if the channel is empty.
  if ch.count == 0:
    result.hasValue = false
    return
  result.value    = ch.buf[ch.head]
  result.hasValue = true
  ch.head = (ch.head + 1) mod ServerChanDepth
  dec ch.count

proc serverChanRegister*(ch: var ServerChan) =
  ## Add ch to the global registry. No-op when registry is full.
  if registryCount < MaxServerChans:
    registry[registryCount] = addr ch
    inc registryCount

proc serverChanFind*(name: string): ptr ServerChan =
  ## Look up a channel by name. Returns nil if not found.
  for i in 0..<registryCount:
    if registry[i] != nil and serverChanName(registry[i][]) == name:
      return registry[i]
  nil
