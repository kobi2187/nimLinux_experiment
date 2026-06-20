# SPDX-License-Identifier: GPL-2.0
## Driver Registry — boot-time driver probe loop
##
## Usage:
##   registerDriver(addr myDriver)   # called once per driver at init
##   discard probeAllDrivers()       # called once during boot
##
## probeAllDrivers() calls init() on every registered DriverVTable in
## registration order. Returns (okCount, failCount).

import ./traits/driver

const MaxDrivers* = 32

var
  registry:      array[MaxDrivers, ptr DriverVTable]
  registryCount: int = 0

proc resetRegistry*() =
  ## Reset the registry (used in tests only).
  registryCount = 0
  for i in 0..<MaxDrivers:
    registry[i] = nil

proc registerDriver*(d: ptr DriverVTable) =
  ## Add a driver to the probe list. Silently ignored if registry is full.
  if registryCount < MaxDrivers:
    registry[registryCount] = d
    inc registryCount

proc probeAllDrivers*(): tuple[ok: int, fail: int] =
  ## Call init() on every registered driver in order.
  ## Returns count of (succeeded, failed).
  var ok   = 0
  var fail = 0
  for i in 0..<registryCount:
    let d = registry[i]
    if d == nil: continue
    let r = d.init()
    if r == drOk:
      inc ok
    else:
      inc fail
  (ok, fail)
