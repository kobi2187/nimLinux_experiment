# SPDX-License-Identifier: GPL-2.0
## The display port (D3 option A, human 2026-11-17): the only way to draw on the screen is to hold this port's
## handle, which the launcher moves to a program whose manifest says `grant display`. One holder at a time.
## There is no operation that reads the screen back (capture is a separate right held by the compositor,
## decided as Option A on the same day): this port only writes.
##
## Requests (each answered): info, modes, setMode, present. No events. Payloads are plain data; a present names
## a BUFFER the caller owns by its handle (data moves by ownership, never by pointer).
import port

const
  MaxWireModes* = 8                 ## = kernel/display/display_checks.MaxModes (a static check lives in display.nim)
  DisplayFormatB8G8R8X8* = 1'u32

type
  DisplayOp* = enum
    doInfo           ## reply: DisplayInfoWire (the CURRENT mode)
    doModes          ## reply: DisplayModesWire (the modes setMode accepts, ascending)
    doSetMode        ## request: SetModeWire; the caller must hold the port (it is the owner)
    doPresent        ## request: PresentWire

  DisplayInfoWire* {.packed.} = object
    width*, height*, format*, strideBytes*: uint32

  ModeWire* {.packed.} = object
    w*, h*: uint32

  DisplayModesWire* {.packed.} = object
    count*: uint8                   ## how many entries of `modes` are valid
    modes*: array[MaxWireModes, ModeWire]

  SetModeWire* {.packed.} = object
    w*, h*: uint32

  PresentWire* {.packed.} = object
    handle*, strideBytes*: uint32   ## the owned buffer, and its row stride in bytes
    sx*, sy*, w*, h*, dx*, dy*: int32

proc displayRequest*(op: DisplayOp): PortMsg =
  PortMsg(cls: mcRequest, status: psOk, op: uint16(ord(op)))

proc displayOpOf*(m: PortMsg; op: var DisplayOp): PortStatus =
  ## The operation a request names, or psBadOp / psBadArg.
  if m.cls != mcRequest: return psBadArg
  if int(m.op) > ord(high(DisplayOp)): return psBadOp
  op = DisplayOp(m.op)
  psOk
