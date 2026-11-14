# SPDX-License-Identifier: GPL-2.0
## Shared ABI vtable wiring — imported by every kernel model.
##
## Each model calls wireSharedAbi(av) to fill the ABI (identical across
## monolithic/microkernel/sasos), then assigns nimixAbi = av.

import nimix_abi
import nimix_abi_impl
import ../buffers/kbuffers
import ../display/display
import ../handles/khandles

proc wireSharedAbi*(av: var NimixAbiVTable) =
  ## Wire all shared ABI procs into av.
  av.allocRegion    = abiAllocRegion
  av.freeRegion     = abiFreeRegion
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
  av.chanCreate     = abiChanCreate
  av.capRecv        = abiCapRecv
  av.bufCreate      = abiBufCreate
  av.bufMap         = abiBufMap
  av.bufClose       = abiBufClose
  av.bufSeal        = abiBufSeal
  av.bufReturn      = abiBufReturn
  av.bufMsgSend     = proc(name: cstring; data: pointer; dataLen: int; hs: pointer): int {.nimcall.} =
    abiBufMsgSend(name, data, dataLen, cast[ptr BufMsgHandles](hs))
  av.bufMsgRecv     = proc(tok: uint64; buf: pointer; bufLen: int; hs: pointer): int {.nimcall.} =
    abiBufMsgRecv(tok, buf, bufLen, cast[ptr BufMsgHandles](hs))
  av.displayInfo    = abiDisplayInfo
  av.displayPresent = abiDisplayPresent
  av.displayModes   = abiDisplayModes
  av.displaySetMode = abiDisplaySetMode
  av.chanPair       = abiChanPair
  av.chanWrite      = abiChanWrite
  av.chanRead       = abiChanRead
  av.handleClose    = abiHandleClose
  av.handleDup      = abiHandleDup
  av.chanStatus     = abiChanStatus
  av.wait           = abiWait
  av.chanWriteBatch = abiChanWriteBatch
  av.chanReadBatch  = abiChanReadBatch
  av.kernelCalls    = abiKernelCalls
