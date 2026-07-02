# SPDX-License-Identifier: GPL-2.0
## Named mailbox registry — resolve a mailbox by name and post to it.
##
## Mailbox[N] is generic, so the registry stores an untyped pointer plus a
## nimcall post/tryRecv thunk pair (the vtable pattern used throughout the
## kernel). --os:any: fixed-size arrays, no stdlib containers.
import mailbox

const
  MbNameLen*    = 64
  MaxMailboxes* = 32

type
  PostThunk*    = proc(mb: pointer; msg: MailMsg): bool {.nimcall.}
  RecvThunk*    = proc(mb: pointer): MaybeMail {.nimcall.}
  MailboxRef* = object
    name*:    array[MbNameLen, char]
    mb*:      pointer
    post*:    PostThunk
    tryRecv*: RecvThunk

var registry: array[MaxMailboxes, MailboxRef]
var count: int = 0

proc mbRegistryInit*() =
  count = 0
  for i in 0..<MaxMailboxes: registry[i].mb = nil

proc fillName(dst: var array[MbNameLen, char]; src: string) =
  let lim = if src.len < MbNameLen - 1: src.len else: MbNameLen - 1
  for i in 0..<lim: dst[i] = src[i]
  dst[lim] = '\0'

proc nameEq(n: array[MbNameLen, char]; src: string): bool =
  var i = 0
  while i < MbNameLen and n[i] != '\0':
    if i >= src.len or n[i] != src[i]: return false
    inc i
  i == src.len

proc mbRegister*(name: string; mb: pointer; post: PostThunk; tryRecv: RecvThunk) =
  assert mb != nil, "mbRegister: nil mailbox"
  if count >= MaxMailboxes: return
  fillName(registry[count].name, name)
  registry[count].mb      = mb
  registry[count].post    = post
  registry[count].tryRecv = tryRecv
  inc count

proc mbFind*(name: string): ptr MailboxRef =
  for i in 0..<count:
    if registry[i].mb != nil and nameEq(registry[i].name, name):
      return addr registry[i]
  nil

proc mbPostByName*(name: string; msg: MailMsg): bool =
  let r = mbFind(name)
  if r == nil: return false
  r.post(r.mb, msg)
