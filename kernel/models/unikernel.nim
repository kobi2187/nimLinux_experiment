# SPDX-License-Identifier: GPL-2.0
## Unikernel Model — Stub
##
## Future: single-application library OS with no scheduler overhead.
## Currently delegates to the monolithic implementation.

import ./monolithic

proc initUnikernelModel*() =
  ## Stub: initialises using the monolithic model internals.
  ## Replace with single-address-space optimisation in a later task.
  initMonolithicModel()
