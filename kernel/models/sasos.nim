# SPDX-License-Identifier: GPL-2.0
## Single Address Space OS Model (SASOS)
##
## Inspired by Microsoft Research's Singularity OS.
##
## Key idea: all "processes" share one virtual address space.
## Isolation is enforced by Nim's type system, not hardware MMU rings:
##   - Module boundaries are opaque handles (distinct types)
##   - No unsafe pointer sharing between modules (enforced at compile time)
##   - IPC is direct ring-buffer calls — no kernel mediation, no context switch
##   - Result: microkernel-level safety + monolithic-level speed
##
## Why this fits Nim perfectly:
##   - Nim's distinct types make cross-module pointer confusion a compile error
##   - --mm:arc means no GC pauses, deterministic memory
##   - No need for page-table switches = dramatically faster task switching
##
## To select: compile with -d:kernelModel=sasos
##
## Current status: delegates to monolithic for scheduling/IPC internals.
## The SASOS-specific isolation layer (SoftwareIsolatedProcess, capability tokens)
## will be built on top in a future task.

import ./monolithic
import ../traits/scheduler
import ../traits/ipc
import ../../core/log_types

# ── Software Isolated Process (SIP) ─────────────────────────────────────────
#
# In Singularity, a SIP is the unit of isolation — equivalent to a process
# but without its own page table. The kernel knows which SIP owns which memory
# via type-safe capability handles.
#
# A SIP can only communicate with other SIPs through typed message channels.
# There is no "raw pointer" IPC — everything goes through the channel interface.

type
  SipId* = distinct uint32
    ## Opaque Software Isolated Process identifier.
    ## Distinct from TaskId — a SIP may contain multiple tasks.

  SipCapability* = distinct uint64
    ## Unforgeable capability token granting access to a resource.
    ## Passed between SIPs via typed message channels only.
    ## A SIP that does not hold a capability cannot access the resource.

proc initSasosModel*() =
  ## Initialise the SASOS kernel model.
  ## Currently uses the monolithic scheduler and IPC internals.
  ## SASOS-specific: capability table, SIP registry, and typed channel
  ## enforcement will layer on top in future tasks.
  initMonolithicModel()
  # TODO (SASOS layer 2): initialise SIP registry
  # TODO (SASOS layer 2): initialise capability table
  # TODO (SASOS layer 2): wrap ipc.send/recv with capability checks
