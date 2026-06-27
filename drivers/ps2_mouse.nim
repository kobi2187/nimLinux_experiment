# SPDX-License-Identifier: GPL-2.0
## PS/2 Mouse Driver
##
## Handles IRQ12, decodes the 3-byte PS/2 mouse packet protocol, and publishes
## mouse.move / mouse.click events to the event_server.
##
## Port map:
##   0x60 = data port  (read byte from 8042 output buffer)
##   0x64 = status/command port
##
## Packet format (3 bytes):
##   byte 0: flags — YO XO YS XS 1 M R L   (Y/X overflow, Y/X sign, btn bits)
##   byte 1: X movement (signed, two's complement via sign bit in byte 0)
##   byte 2: Y movement (signed, two's complement; Y axis is inverted vs screen)
##
## 4-byte IntelliMouse extension (scroll wheel) is not used — 3-byte only.

import ../arch/x86_64/cpu_primitives
import ../kernel/traits/driver

const
  Ps2DataPort*    = 0x60'u16
  Ps2CmdPort*     = 0x64'u16
  MouseIrq*       = 12'u8
  MouseBtnLeft*   = 0x01'u8
  MouseBtnRight*  = 0x02'u8
  MouseBtnMiddle* = 0x04'u8
  MouseOverflow*  = 0xC0'u8   # X or Y overflow bits in byte 0

# Packet reassembly state
var
  mousePkt:   array[3, uint8]
  mousePktIdx: int = 0

type
  MouseMoveEvent* {.packed.} = object
    dx*: int8
    dy*: int8

  MouseClickEvent* {.packed.} = object
    buttons*: uint8   # bit 0=left, 1=right, 2=middle

proc ps2MouseWaitWrite() {.inline.} =
  ## Spin until the 8042 input buffer is empty (safe to write command).
  var timeout = 100_000
  while (inb(Ps2CmdPort) and 0x02'u8) != 0 and timeout > 0:
    dec timeout

proc ps2MouseWaitRead() {.inline.} =
  ## Spin until the 8042 output buffer has data ready to read.
  var timeout = 100_000
  while (inb(Ps2CmdPort) and 0x01'u8) == 0 and timeout > 0:
    dec timeout

proc ps2MouseSendCmd(cmd: uint8) {.inline.} =
  ## Route a byte to the mouse port via the 8042 controller.
  ps2MouseWaitWrite()
  outb(Ps2CmdPort, 0xD4'u8)   # tell 8042: next byte goes to mouse
  ps2MouseWaitWrite()
  outb(Ps2DataPort, cmd)

proc ps2MouseEnable() =
  ## Enable the auxiliary (mouse) port on the 8042 controller.
  ps2MouseWaitWrite()
  outb(Ps2CmdPort, 0xA8'u8)   # enable aux device
  # Enable mouse interrupts via 8042 command byte (bit 1 = aux IRQ enable)
  ps2MouseWaitWrite()
  outb(Ps2CmdPort, 0x20'u8)   # read current command byte
  ps2MouseWaitRead()
  var compaq = inb(Ps2DataPort) or 0x02'u8   # set aux IRQ enable bit
  compaq = compaq and not 0x20'u8             # clear aux clock disable bit
  ps2MouseWaitWrite()
  outb(Ps2CmdPort, 0x60'u8)   # write command byte back
  ps2MouseWaitWrite()
  outb(Ps2DataPort, compaq)
  # Tell mouse to use default settings and start streaming
  ps2MouseSendCmd(0xF6'u8)   # set defaults
  ps2MouseWaitRead()
  discard inb(Ps2DataPort)   # discard ACK
  ps2MouseSendCmd(0xF4'u8)   # enable streaming
  ps2MouseWaitRead()
  discard inb(Ps2DataPort)   # discard ACK

type
  MousePacket* = object
    valid*:   bool
    dx*:      int8
    dy*:      int8
    buttons*: uint8  # MouseBtnLeft | MouseBtnRight | MouseBtnMiddle

proc mouseDecodePkt*(flags, rawX, rawY: uint8): MousePacket =
  ## Pure decoder: given the 3 packet bytes, return the interpreted delta/buttons.
  ## Returns valid=false when the overflow bits are set.
  if (flags and MouseOverflow) != 0:
    return MousePacket(valid: false)
  # The 8-bit raw value IS the two's complement delta; sign bit in byte 0 is bit 8
  # of a 9-bit value. Overflow already discarded above, so cast is safe.
  let dx = cast[int8](rawX)
  let dy = cast[int8](rawY)
  MousePacket(
    valid:   true,
    dx:      dx,
    dy:      -dy,   # PS/2 +Y = up; invert for screen coordinates
    buttons: flags and (MouseBtnLeft or MouseBtnRight or MouseBtnMiddle)
  )

proc mouseReassemble*(b: uint8): MousePacket =
  ## Feed one byte into the packet reassembler.
  ## Returns a valid MousePacket when all 3 bytes have arrived; valid=false otherwise.

  # Byte 0 must have the always-1 bit (bit 3) set — use as sync guard
  if mousePktIdx == 0 and (b and 0x08'u8) == 0:
    return MousePacket(valid: false)

  mousePkt[mousePktIdx] = b
  inc mousePktIdx
  if mousePktIdx < 3:
    return MousePacket(valid: false)  # packet incomplete

  mousePktIdx = 0
  mouseDecodePkt(mousePkt[0], mousePkt[1], mousePkt[2])

proc mouseProcessByte*(b: uint8) =
  ## Feed one byte into the reassembler; publish events when a packet completes.
  ## In tests (without kernelFull) the reassembler runs but no events fire.
  discard mouseReassemble(b)

proc mouseReset*() =
  ## Reset the packet reassembler to the start-of-packet state. Useful in tests.
  mousePktIdx = 0

proc mouseInit(): DriverResult {.nimcall.} =
  mousePktIdx = 0
  drOk

proc mouseDeinit(): DriverResult {.nimcall.} =
  drOk

let ps2MouseDriver* = DriverVTable(
  name:   "ps2_mouse",
  init:   mouseInit,
  deinit: mouseDeinit,
  irq:    nil
)

when defined(kernelFull):
  import ../kern/interrupts
  import ../drivers/pic
  import ../kernel/event_server

  proc mouseIrqHandler*(ctx: ptr ExceptionContext) {.nimcall.} =
    ## IRQ12 handler — accumulates 3-byte packet, then publishes events.
    let b = inb(Ps2DataPort)
    picEoi(MouseIrq)
    let pkt = mouseReassemble(b)
    if not pkt.valid:
      return
    if pkt.dx != 0 or pkt.dy != 0:
      var mv = MouseMoveEvent(dx: pkt.dx, dy: pkt.dy)
      eventPublish("mouse.move", addr mv, sizeof(MouseMoveEvent))
    if pkt.buttons != 0:
      var cl = MouseClickEvent(buttons: pkt.buttons)
      eventPublish("mouse.click", addr cl, sizeof(MouseClickEvent))

  proc mouseRegisterHandler*() =
    ## Enable the mouse port and register the IRQ12 handler.
    ## Call after initInterruptSystem(), picInit(), and picUnmask(2) (cascade).
    ps2MouseEnable()
    let vec = irqToVector(int(MouseIrq))
    let mgr = getInterruptManager()
    discard mgr.registerExceptionHandler(uint32(vec), mouseIrqHandler)
