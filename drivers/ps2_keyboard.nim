# SPDX-License-Identifier: GPL-2.0
## PS/2 Keyboard Driver
##
## Handles IRQ1, reads Set 1 scancodes from port 0x60, translates to ASCII.
## Characters are stored in a small ring buffer for the shell to read.
##
## Port map:
##   0x60 = data port (read scancode)
##   0x64 = status/command port

import ../arch/x86_64/cpu_primitives
import ../kernel/traits/driver

const
  Ps2DataPort*   = 0x60'u16
  Ps2StatusPort* = 0x64'u16
  KeyboardIrq*   = 1'u8
  KbdBufSize     = 64

# US QWERTY Set 1 make-code scancode table (index = scancode, value = ASCII char)
# Break codes (key release) have bit 7 set and are filtered out before lookup.
const ScancodeTable: array[128, char] = [
  '\0', '\x1B', '1',  '2',  '3',  '4',  '5',  '6',   # 0x00-0x07
  '7',  '8',  '9',  '0',  '-',  '=',  '\b', '\t',     # 0x08-0x0F
  'q',  'w',  'e',  'r',  't',  'y',  'u',  'i',      # 0x10-0x17
  'o',  'p',  '[',  ']',  '\n', '\0', 'a',  's',       # 0x18-0x1F
  'd',  'f',  'g',  'h',  'j',  'k',  'l',  ';',      # 0x20-0x27
  '\'', '`',  '\0', '\\', 'z',  'x',  'c',  'v',      # 0x28-0x2F
  'b',  'n',  'm',  ',',  '.',  '/',  '\0', '*',       # 0x30-0x37
  '\0', ' ',  '\0', '\0', '\0', '\0', '\0', '\0',      # 0x38-0x3F
  '\0', '\0', '\0', '\0', '\0', '\0', '\0', '7',       # 0x40-0x47
  '8',  '9',  '-',  '4',  '5',  '6',  '+',  '1',      # 0x48-0x4F
  '2',  '3',  '0',  '.',  '\0', '\0', '\0', '\0',      # 0x50-0x57
  '\0', '\0', '\0', '\0', '\0', '\0', '\0', '\0',      # 0x58-0x5F
  '\0', '\0', '\0', '\0', '\0', '\0', '\0', '\0',      # 0x60-0x67
  '\0', '\0', '\0', '\0', '\0', '\0', '\0', '\0',      # 0x68-0x6F
  '\0', '\0', '\0', '\0', '\0', '\0', '\0', '\0',      # 0x70-0x77
  '\0', '\0', '\0', '\0', '\0', '\0', '\0', '\0'       # 0x78-0x7F
]

proc scancodeToAscii*(scancode: uint8): char =
  ## Translate a PS/2 Set 1 make scancode to an ASCII character.
  ## Returns '\0' for break codes (bit 7 set) or unmapped keys.
  if (scancode and 0x80'u8) != 0: return '\0'  # break code = key release
  ScancodeTable[int(scancode)]

# Ring buffer for keyboard input
var
  kbdBuf:   array[KbdBufSize, char]
  kbdHead:  int = 0
  kbdTail:  int = 0
  kbdCount: int = 0

proc kbdBufPush(c: char) {.inline.} =
  if kbdCount < KbdBufSize:
    kbdBuf[kbdTail] = c
    kbdTail = (kbdTail + 1) mod KbdBufSize
    inc kbdCount

proc kbdRead*(): char =
  ## Read the next character from the keyboard buffer.
  ## Returns '\0' if the buffer is empty (non-blocking).
  if kbdCount == 0: return '\0'
  result = kbdBuf[kbdHead]
  kbdHead = (kbdHead + 1) mod KbdBufSize
  dec kbdCount

proc kbdReady*(): bool {.inline.} =
  ## Returns true if at least one character is waiting in the buffer.
  kbdCount > 0

proc kbdIrqHandlerLegacy*(vector: uint8) {.nimcall.} =
  ## Legacy IRQ1 handler (driver-registry path) — reads scancode, pushes ASCII to buffer.
  let scancode = inb(Ps2DataPort)
  let ch = scancodeToAscii(scancode)
  if ch != '\0':
    kbdBufPush(ch)

proc kbdInit(): DriverResult {.nimcall.} =
  kbdHead = 0; kbdTail = 0; kbdCount = 0
  # Basic PS/2 enable — controller usually ready after BIOS, so just clear buffer
  # Full init (8042 controller setup) can be added later for robustness
  drOk

proc kbdDeinit(): DriverResult {.nimcall.} =
  drOk

let ps2KeyboardDriver* = DriverVTable(
  name:   "ps2_keyboard",
  init:   kbdInit,
  deinit: kbdDeinit,
  irq:    kbdIrqHandlerLegacy
)

# IRQ handler and registration — only compiled when building the full kernel
# (i.e. kern/interrupts.nim is in scope). Host tests skip this section.
when defined(kernelFull):
  import ../kern/interrupts
  import ../drivers/pic
  import ../kernel/event_server

  proc kbdIrqHandler*(ctx: ptr ExceptionContext) {.nimcall.} =
    ## IRQ1 handler — reads scancode, publishes key.down event.
    let scancode = inb(Ps2DataPort)   # read from PS2 data port
    picEoi(1)                          # IRQ1 → PIC line 1
    # Also push to ring buffer for shell reads
    let ch = scancodeToAscii(scancode)
    if ch != '\0':
      kbdBufPush(ch)
    # Publish scancode as 1-byte payload
    var sc = scancode
    eventPublish("key.down", addr sc, 1)

  proc kbdRegisterHandler*() =
    ## Register the PS2 keyboard IRQ handler with the global interrupt manager.
    ## Call after initInterruptSystem() and picInit().
    let mgr = getInterruptManager()
    discard mgr.registerExceptionHandler(IRQ_KEYBOARD, kbdIrqHandler)
