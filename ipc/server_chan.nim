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
  MaxOwnedChans*     = 8     ## Pool for channels created by userspace servers
  MaxMsgFlights*     = 4     ## buffer handles travelling with one message (ipc/buffers)

type
  ServerMsg* = object
    len*:  uint16
    data*: array[ServerMsgMaxLen, byte]
    nFlights*: uint8                          ## buffer transfers riding along
    flights*:  array[MaxMsgFlights, int16]    ## in-flight ids (ipc/buffers/state)

  ServerChan* = object
    name*: array[ServerChanNameLen, char]
    buf:   array[ServerChanDepth, ServerMsg]
    head:  int
    tail:  int
    count: int
    recvCap*: uint64   ## receive capability token; 0 = kernel-owned (plain recv)

  ## Minimal Option type — avoids std/options dependency under --os:any.
  MaybeMsg* = object
    hasValue*: bool
    value*:    ServerMsg

var onMsgDropped*: proc(m: var ServerMsg) {.nimcall.}
  ## A message carrying buffer transfers will never be delivered (channel
  ## released, or drained by a receiver that takes no handles): the buffers
  ## glue cancels its flights so nothing leaks.

proc dropFlights*(m: var ServerMsg) =
  if m.nFlights > 0 and onMsgDropped != nil: onMsgDropped(m)
  m.nFlights = 0

var
  registry:      array[MaxServerChans, ptr ServerChan]
  registryCount: int = 0
  ownedPool:     array[MaxOwnedChans, ServerChan]
  ownedUsed:     array[MaxOwnedChans, bool]

proc serverChanRegistryInit*() =
  ## Reset the global channel registry (call once at kernel init or in tests).
  registryCount = 0
  for i in 0..<MaxServerChans: registry[i] = nil
  for i in 0..<MaxOwnedChans: ownedUsed[i] = false

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

proc nameEq(stored: array[ServerChanNameLen, char]; name: cstring): bool =
  ## Allocation-free compare of a stored (NUL-terminated, truncated) name.
  for i in 0 ..< ServerChanNameLen:
    if stored[i] != name[i]: return false
    if stored[i] == '\0': return true
  false

proc serverChanFind*(name: cstring): ptr ServerChan =
  ## Look up a channel by name. Returns nil if not found. Allocation-free:
  ## the kernel IPC path must not depend on the kernel string heap.
  if name == nil: return nil
  for i in 0..<registryCount:
    if registry[i] != nil and nameEq(registry[i].name, name):
      return registry[i]
  nil

proc serverChanFind*(name: string): ptr ServerChan =
  serverChanFind(name.cstring)

# ── Server-owned channels (microkernel: servers own their endpoints) ──────────
# A userspace server creates its channel and receives through a capability; the
# kernel only provides the mailbox. Names are first-come: a taken name fails.

proc serverChanAllocOwned*(name: cstring; recvCap: uint64): ptr ServerChan =
  ## Create + register a channel bound to `recvCap` (must be non-zero).
  ## nil when the name is empty or taken, or the pool / registry is full.
  ## Allocation-free (kernel path): the name is copied byte by byte.
  assert recvCap != 0, "owned channel needs a receive capability"
  if name == nil or name[0] == '\0' or serverChanFind(name) != nil or
     registryCount >= MaxServerChans:
    return nil
  for i in 0..<MaxOwnedChans:
    if not ownedUsed[i]:
      ownedUsed[i] = true
      let ch = addr ownedPool[i]
      zeroMem(ch, sizeof(ServerChan))
      var n = 0
      while n < ServerChanNameLen - 1 and name[n] != '\0':
        ch.name[n] = name[n]; inc n
      ch.recvCap = recvCap
      serverChanRegister(ch[])
      return ch
  nil

proc serverChanRelease*(ch: ptr ServerChan) =
  ## Unregister a server-owned channel and return its pool slot (owner died).
  ## Senders see "not found" from then on; the name is free to re-create.
  while ch.count > 0:                       # queued messages die with it
    var m = ch.buf[ch.head]
    ch.head = (ch.head + 1) mod ServerChanDepth
    dec ch.count
    dropFlights(m)
  for i in 0..<registryCount:
    if registry[i] == ch:
      for j in i ..< registryCount - 1: registry[j] = registry[j + 1]
      dec registryCount
      registry[registryCount] = nil
      break
  for i in 0..<MaxOwnedChans:
    if addr(ownedPool[i]) == ch: ownedUsed[i] = false

iterator ownedChannels*(): ptr ServerChan =
  ## Every registered server-owned channel (recvCap != 0).
  var i = registryCount - 1
  while i >= 0:            # backwards: callers may release as they go
    if registry[i] != nil and registry[i].recvCap != 0: yield registry[i]
    dec i

proc serverChanFindByCap*(recvCap: uint64): ptr ServerChan =
  ## The channel a receive capability is bound to, or nil.
  if recvCap == 0: return nil
  for i in 0..<registryCount:
    if registry[i] != nil and registry[i].recvCap == recvCap:
      return registry[i]
  nil

# ── MsgPack helpers ───────────────────────────────────────────────────────────
# Encode/decode ServerMsg payloads using the kernel MsgPack encoder.
# Callers in --os:any context use these instead of raw byte manipulation.

import ../kernel/ipc/msgpack_chan

proc serverMsgFromMp*(buf: MpBuf): ServerMsg =
  ## Pack an MpBuf into a ServerMsg (copies bytes, sets len).
  let n = if buf.pos < ServerMsgMaxLen: buf.pos else: ServerMsgMaxLen
  result.len = uint16(n)
  for i in 0 ..< n:
    result.data[i] = buf.data[i]

proc serverMsgToMp*(msg: ServerMsg): MpBuf =
  ## Unpack a ServerMsg back into an MpBuf for decoding.
  result.pos = 0
  let n = if int(msg.len) < 256: int(msg.len) else: 255
  for i in 0 ..< n:
    result.data[i] = msg.data[i]
