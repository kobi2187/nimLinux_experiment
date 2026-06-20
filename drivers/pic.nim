# SPDX-License-Identifier: GPL-2.0
## PIC 8259A — Programmable Interrupt Controller
##
## Two cascaded 8259A chips handle hardware IRQs 0-15.
## BIOS maps them to vectors 0x08-0x0F/0x70-0x77 which collide with
## CPU exception vectors. We remap to 0x20-0x2F (safe range).
##
## After picInit(), call picUnmask(irq) then sti() to start receiving IRQs.

import ../arch/x86_64/cpu_primitives

const
  PicMasterCmd*    = 0x20'u16  ## Master PIC command port
  PicMasterData*   = 0x21'u16  ## Master PIC data/mask port
  PicSlaveCmd*     = 0xA0'u16  ## Slave PIC command port
  PicSlaveData*    = 0xA1'u16  ## Slave PIC data/mask port
  PicMasterOffset* = 0x20'u8   ## IRQ  0-7  → vectors 0x20-0x27
  PicSlaveOffset*  = 0x28'u8   ## IRQ  8-15 → vectors 0x28-0x2F
  PicEoi*          = 0x20'u8   ## End-of-interrupt command byte

proc irqToVector*(irq: int): uint8 {.inline.} =
  ## Convert IRQ number (0-15) to remapped interrupt vector.
  if irq < 8: uint8(irq) + PicMasterOffset
  else:       uint8(irq - 8) + PicSlaveOffset

proc picIoWait() {.inline.} =
  ## Short delay after PIC port writes — some hardware needs settling time.
  outb(0x80'u16, 0x00'u8)

proc picInit*() =
  ## Remap both PICs and mask all IRQs.
  ## Call picUnmask(irq) for each IRQ you want to receive.

  # ICW1: begin initialisation sequence, cascade mode, ICW4 required
  outb(PicMasterCmd,  0x11'u8); picIoWait()
  outb(PicSlaveCmd,   0x11'u8); picIoWait()

  # ICW2: vector offsets
  outb(PicMasterData, PicMasterOffset); picIoWait()
  outb(PicSlaveData,  PicSlaveOffset);  picIoWait()

  # ICW3: cascade wiring — master: slave on IR2; slave: cascade id = 2
  outb(PicMasterData, 0x04'u8); picIoWait()
  outb(PicSlaveData,  0x02'u8); picIoWait()

  # ICW4: 8086/88 mode
  outb(PicMasterData, 0x01'u8); picIoWait()
  outb(PicSlaveData,  0x01'u8); picIoWait()

  # Mask all IRQs — caller unmasks what it needs
  outb(PicMasterData, 0xFF'u8)
  outb(PicSlaveData,  0xFF'u8)

proc picEoi*(irq: uint8) {.inline.} =
  ## Send End-Of-Interrupt. Must be called at the END of every IRQ handler.
  if irq >= 8:
    outb(PicSlaveCmd, PicEoi)   # cascade: ack slave first
  outb(PicMasterCmd, PicEoi)

proc picUnmask*(irq: uint8) {.inline.} =
  ## Enable (unmask) a specific IRQ line so it can fire.
  if irq < 8:
    outb(PicMasterData, inb(PicMasterData) and not (1'u8 shl int(irq)))
  else:
    outb(PicSlaveData,  inb(PicSlaveData)  and not (1'u8 shl int(irq - 8)))

proc picMask*(irq: uint8) {.inline.} =
  ## Disable (mask) a specific IRQ line.
  if irq < 8:
    outb(PicMasterData, inb(PicMasterData) or (1'u8 shl int(irq)))
  else:
    outb(PicSlaveData,  inb(PicSlaveData)  or (1'u8 shl int(irq - 8)))
