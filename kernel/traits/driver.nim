# SPDX-License-Identifier: GPL-2.0
## Driver Trait — Interface Only
##
## All device drivers expose a DriverVTable. The kernel's driver registry
## stores these vtables and calls init/deinit/irq uniformly.

type
  DriverResult* = enum
    drOk        = 0
    drNotFound     ## Hardware device not detected
    drInitFailed   ## Initialization sequence failed
    drBusy         ## Device is currently busy
    drInvalidOp    ## Operation not supported by this driver

  IrqHandler* = proc(vector: uint8) {.nimcall.}
    ## Called by the interrupt dispatcher when this driver's IRQ fires.
    ## Must be fast — runs in interrupt context (no blocking, no alloc).

  DriverVTable* = object
    ## Virtual dispatch table for a device driver.
    name*:   cstring       ## Human-readable driver name (for logging)
    init*:   proc(): DriverResult {.nimcall.}
    deinit*: proc(): DriverResult {.nimcall.}
    irq*:    IrqHandler    ## nil if this driver has no IRQ
