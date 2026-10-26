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
  import ../kernel/process_table
  import ../arch/x86_64/tss
  import ../core/log

  # Assembly helpers declared here; defined in boot_asm.S
  proc preemptiveSwitch(oldRsp: ptr uint64; newRsp: uint64) {.importc, cdecl.}
  proc fxSave(dst: pointer) {.importc, cdecl.}
  proc fxRestore(src: pointer) {.importc, cdecl.}

  proc pitIrqHandler*(ctx: ptr ExceptionContext) {.nimcall.} =
    ## IRQ0 — preemptive scheduler tick.
    ## 1. Bookkeeping (tick, stats, wake expired sleepers)
    ## 2. EOI so PIC can fire next IRQ
    ## 3. Pick next task; if different, save FPU + swap RSP via iretq frame
    pitTick()
    procTickCurrent(procTable)
    procWakeExpired(procTable)
    picEoi(0)

    let next = procPickNext(procTable)
    if next < 0 or next == procTable.current:
      return  # no switch needed
    if procTable.tasks[next].rsp == 0:
      # Never switch to a context that was never saved (would `ret` to 0).
      klogInt(llError, "pit: refusing switch to task with rsp=0, slot=", int64(next))
      klogInt(llError, "pit:   its pid=", int64(procTable.tasks[next].pid))
      klogInt(llError, "pit:   current slot=", int64(procTable.current))
      return

    let prev = procTable.current
    if prev >= 0 and procTable.tasks[prev].used and not kstackIntact(prev):
      # Loud, not silent: an overflowed kstack has already written into the
      # neighbouring procTable entries.
      klogInt(llError, "pit: kernel stack overflow in task slot=", int64(prev))
    procTable.current = next
    procTable.tasks[next].state = ptsRunning
    inc procTable.tasks[next].switches
    inc procTable.stats.totalSwitches

    # Save outgoing task's FPU state (lazy: only if it used FPU)
    if prev >= 0 and procTable.tasks[prev].used:
      # Only a Running task goes back to Ready. A Blocked one (sleeping, out of
      # its ring) must stay Blocked so procWakeExpired re-inserts it.
      if procTable.tasks[prev].state == ptsRunning:
        procTable.tasks[prev].state = ptsReady
      fxSave(addr procTable.tasks[prev].fpuState[0])
      procTable.tasks[prev].fpuValid = true

    # Restore incoming task's FPU state
    if procTable.tasks[next].fpuValid:
      fxRestore(addr procTable.tasks[next].fpuState[0])

    # Update TSS rsp0 so the next IRQ while this task runs uses its kernel stack
    globalTss.rsp0 = kstackTop(next)

    # Preemptive RSP swap: we are inside isr_common_stub's GPR save area.
    # ctx points at rax on the stack (= current RSP inside the ISR frame).
    # preemptiveSwitch saves this RSP into prev.rsp and loads next.rsp.
    # When we return from preemptiveSwitch, isr_common_stub's pop+iretq
    # will restore the new task's saved register state and resume it.
    if prev >= 0:
      preemptiveSwitch(addr procTable.tasks[prev].rsp,
                       procTable.tasks[next].rsp)
    else:
      # No previous task (boot/idle) — just load new task's stack.
      # We can't save "nowhere", so just switch RSP directly.
      preemptiveSwitch(addr procTable.tasks[next].rsp,  # dummy write target
                       procTable.tasks[next].rsp)

  proc pitRegisterHandler*() =
    ## Register the PIT IRQ handler with the global interrupt manager.
    ## Call after initInterruptSystem() and pitInit().
    let mgr = getInterruptManager()
    discard mgr.registerExceptionHandler(IRQ_TIMER, pitIrqHandler)
