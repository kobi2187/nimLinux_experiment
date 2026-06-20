# SPDX-License-Identifier: GPL-2.0
## IPC Trait — Interface Only
##
## Inter-task communication channel interface.
## Monolithic: direct memory copy. Microkernel: message passing via kernel.

import ../../core/types
import ../../kernel/config
import ./scheduler

type
  ChannelId* = distinct uint32
    ## Opaque channel identifier.

  Message* = object
    ## A fixed-size IPC message.
    sender*: TaskId       ## TaskId of the sending task
    size*:   uint16       ## Bytes of data actually used (≤ MessageSize)
    data*:   array[MessageSize, byte]  ## Message payload

  IpcResult* = enum
    mrOk      = 0
    mrFull       ## Channel send buffer is full
    mrEmpty      ## Channel recv buffer is empty
    mrInvalid    ## Channel ID does not exist or is closed
    mrTimeout    ## Timed out waiting (for blocking variants)

  IpcVTable* = object
    ## Virtual dispatch table for IPC operations.
    send*:    proc(ch: ChannelId, msg: ptr Message): IpcResult {.nimcall.}
    recv*:    proc(ch: ChannelId, msg: ptr Message): IpcResult {.nimcall.}
    tryRecv*: proc(ch: ChannelId, msg: ptr Message): IpcResult {.nimcall.}
    open*:    proc(): Result[ChannelId, IpcResult] {.nimcall.}
    close*:   proc(ch: ChannelId): IpcResult {.nimcall.}

proc `==`*(a, b: ChannelId): bool {.inline.} = uint32(a) == uint32(b)

var ipc*: IpcVTable
  ## Global IPC vtable. Populated by the active kernel model at init time.
