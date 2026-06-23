# SPDX-License-Identifier: GPL-2.0
## Named capability registry.
## Servers register a named cap; apps request it and receive a CapToken.
## Simple fixed-size table — no dynamic allocation.

import capability

const MaxNamedCaps* = 32
const CapNameLen*   = 32

type
  CapRegistryEntry* = object
    name*:    array[CapNameLen, char]
    right*:   CapRight
    valid*:   bool

  CapRegistry* = object
    entries*: array[MaxNamedCaps, CapRegistryEntry]

var gCapRegistry*: CapRegistry

proc capRegistryInit*() =
  for i in 0 ..< MaxNamedCaps:
    gCapRegistry.entries[i].valid = false

proc capRegister*(name: cstring; right: CapRight): bool =
  ## Register a named capability. Returns false if name already exists or table full.
  # Check for duplicate first
  for i in 0 ..< MaxNamedCaps:
    if not gCapRegistry.entries[i].valid: continue
    var j = 0; var match = true
    while j < CapNameLen:
      if gCapRegistry.entries[i].name[j] != name[j]: match = false; break
      if name[j] == '\0': break
      inc j
    if match: return false
  # Find empty slot
  for i in 0 ..< MaxNamedCaps:
    if not gCapRegistry.entries[i].valid:
      var j = 0
      while j < CapNameLen - 1 and name[j] != '\0':
        gCapRegistry.entries[i].name[j] = name[j]; inc j
      gCapRegistry.entries[i].name[j] = '\0'
      gCapRegistry.entries[i].right = right
      gCapRegistry.entries[i].valid = true
      return true
  false

proc capRequest*(name: cstring; pid: uint32): CapToken =
  ## Request a named capability for pid. Returns the token if found, NullCap otherwise.
  for i in 0 ..< MaxNamedCaps:
    if not gCapRegistry.entries[i].valid: continue
    var j = 0
    while j < CapNameLen and name[j] != '\0' and gCapRegistry.entries[i].name[j] != '\0':
      if name[j] != gCapRegistry.entries[i].name[j]: break
      inc j
    if name[j] == '\0' and gCapRegistry.entries[i].name[j] == '\0':
      return capGrant(pid, gCapRegistry.entries[i].right)
  NullCap

proc capUnregister*(name: cstring): bool =
  ## Remove a named capability from registry.
  for i in 0 ..< MaxNamedCaps:
    if not gCapRegistry.entries[i].valid: continue
    var j = 0; var match = true
    while j < CapNameLen:
      if gCapRegistry.entries[i].name[j] != name[j]: match = false; break
      if name[j] == '\0': break
      inc j
    if match:
      gCapRegistry.entries[i].valid = false
      return true
  false
