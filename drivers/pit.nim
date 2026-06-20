# SPDX-License-Identifier: GPL-2.0
## PIT 8253/8254 — Programmable Interval Timer
##
## Drives the kernel scheduler at a configurable Hz rate.
## IRQ0 (vector 0x20 after PIC remapping) fires at `hz` frequency.
##
## Usage:
##   pitInit(100)    # 100Hz = 10ms tick
##   picUnmask(0)    # unmask IRQ0 (from pic.nim)
##   sti()           # enable interrupts

when not defined(noKernelHardware):
  import ../arch/x86_64/cpu_primitives

const
  PitChannel0* = 0x40'u16   ## Channel 0 data port — connected to IRQ0
  PitCmd*      = 0x43'u16   ## Mode/command register
  PitBaseHz    = 1_193_182  ## PIT oscillator frequency (Hz)

var tickCount: uint64 = 0

proc pitTicks*(): uint64 {.inline.} =
  ## Return the number of timer ticks since pitInit() or resetTicks().
  tickCount

proc pitTick*() {.inline.} =
  ## Increment the tick counter. Called by the IRQ0 handler.
  inc tickCount

proc resetTicks*() {.inline.} =
  ## Reset tick counter to zero (used in tests).
  tickCount = 0

proc pitDivisor*(hz: int): uint16 =
  ## Calculate the PIT reload divisor for a given frequency.
  ## PIT counts down from this value at 1,193,182 Hz.
  uint16(PitBaseHz div hz)

when not defined(noKernelHardware):
  proc pitInit*(hz: int = 100) =
    ## Program PIT channel 0 to fire IRQ0 at `hz` Hz.
    ## After calling this, call picUnmask(0) and sti() to start ticks.
    let d = pitDivisor(hz)
    # Command: channel 0, lobyte/hibyte access mode, mode 3 (square wave generator)
    outb(PitCmd,      0x36'u8)
    outb(PitChannel0, uint8(d and 0xFF))          # low byte of divisor
    outb(PitChannel0, uint8((d shr 8) and 0xFF))  # high byte of divisor

# IRQ handler and registration — only compiled when building the full kernel
# (i.e. kern/interrupts.nim is in scope). Host tests skip this section.
when defined(kernelFull):
  import ../kern/interrupts
  import ../drivers/pic

  proc pitIrqHandler*(ctx: ptr ExceptionContext) {.nimcall.} =
    ## IRQ0 interrupt handler registered with the IDT at vector 0x20 (IRQ_TIMER).
    ## Increments the tick counter then sends EOI to unblock the master PIC.
    pitTick()
    picEoi(0)

  proc pitRegisterHandler*() =
    ## Register the PIT IRQ handler with the global interrupt manager.
    ## Call after initInterruptSystem() and pitInit().
    let mgr = getInterruptManager()
    discard mgr.registerExceptionHandler(IRQ_TIMER, pitIrqHandler)
