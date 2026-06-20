# SPDX-License-Identifier: GPL-2.0
## Microkernel Model — Stub
##
## Future: message-passing via a privileged kernel server.
## Currently delegates to the monolithic implementation.

import ./monolithic

proc initMicrokernelModel*() =
  ## Stub: initialises using the monolithic model internals.
  ## Replace with true IPC-based implementation in a later task.
  initMonolithicModel()
