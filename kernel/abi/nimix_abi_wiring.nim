# SPDX-License-Identifier: GPL-2.0
## Shared ABI vtable wiring — imported by every kernel model.
##
## Each model calls wireSharedAbi(av) to fill the procs that are identical
## across monolithic/microkernel/sasos, then sets av.allocRegion and
## av.freeRegion itself before assigning nimixAbi = av.

import nimix_abi
import nimix_abi_impl

proc wireSharedAbi*(av: var NimixAbiVTable) =
  ## Wire all shared ABI procs into av.
  ## Caller must set av.allocRegion / av.freeRegion for its memory model.
  av.write          = abiWrite
  av.exit           = abiExit
  av.chanSend       = abiChanSend
  av.chanRecv       = abiChanRecv
  av.eventPublish   = abiEventPublish
  av.eventSubscribe = abiEventSubscribe
  av.eventPoll      = abiEventPoll
  av.getArgs        = abiGetArgs
  av.procList       = abiProcList
  av.schedStats     = abiSchedStats
  av.procKillPid    = abiProcKillPid
  av.fsReadDir      = abiFsReadDir
  av.fsRead         = abiFsRead
  av.fsWrite        = abiFsWrite
  av.capSend        = abiCapSend
  av.chanCall       = abiChanCall
  av.sleep          = abiSleep
  av.`yield`        = abiYield
  av.sysInfo        = abiSysInfo
  av.grantRegion    = abiGrantRegion
  av.uptimeSecs     = abiUptimeSecs
  av.wallClock      = abiWallClock
  av.mapAnon        = abiMapAnon
  av.freeAnon       = abiFreeAnon
  av.sndPlay        = abiSndPlay
  av.sndDrain       = abiSndDrain
