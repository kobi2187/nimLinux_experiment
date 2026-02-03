# SPDX-License-Identifier: GPL-2.0
## Console Driver - Serial UART 16550 - LAYER 2
##
## Provides kernel console output via serial port (COM1)
## Replaces early VGA text mode output
##
## Standard 16550 UART initialization and output
## Works from kernel_main onwards
## Used for all kernel logging and debugging

import ../core/types
import strformat

# ═══════════════════════════════════════════════════════════════════════════
# UART 16550 Port Addresses and Registers
# ═══════════════════════════════════════════════════════════════════════════

const
  ## COM1 port address (standard)
  UART_COM1* = 0x3F8'u16

  ## Register offsets from base address
  UART_RBR* = 0'u16  # Receive Buffer Register (read)
  UART_THR* = 0'u16  # Transmit Holding Register (write)
  UART_IER* = 1'u16  # Interrupt Enable Register
  UART_FCR* = 2'u16  # FIFO Control Register
  UART_LCR* = 3'u16  # Line Control Register
  UART_MCR* = 4'u16  # Modem Control Register
  UART_LSR* = 5'u16  # Line Status Register
  UART_MSR* = 6'u16  # Modem Status Register
  UART_SR* = 7'u16   # Scratch Register

  ## Divisor registers for baud rate (when DLAB is set)
  UART_DLL* = 0'u16  # Divisor Latch Low
  UART_DLM* = 1'u16  # Divisor Latch High

# ═══════════════════════════════════════════════════════════════════════════
# UART Register Bits
# ═══════════════════════════════════════════════════════════════════════════

const
  ## Line Control Register (LCR)
  UART_LCR_DLAB* = 0x80'u8     # Divisor Latch Access Bit
  UART_LCR_SB* = 0x40'u8       # Set Break
  UART_LCR_EPS* = 0x20'u8      # Even Parity Select
  UART_LCR_PEN* = 0x08'u8      # Parity Enable
  UART_LCR_STB* = 0x04'u8      # Stop Bits (0=1, 1=2)
  UART_LCR_WLS* = 0x03'u8      # Word Length Select (0=5, 1=6, 2=7, 3=8)

  ## Line Status Register (LSR)
  UART_LSR_TEMT* = 0x40'u8     # Transmitter Empty
  UART_LSR_THRE* = 0x20'u8     # Transmit Holding Register Empty
  UART_LSR_RDR* = 0x01'u8      # Receiver Data Ready

  ## FIFO Control Register (FCR)
  UART_FCR_ENABLE* = 0x01'u8   # Enable FIFO
  UART_FCR_CLEAR_RX* = 0x02'u8 # Clear receive FIFO
  UART_FCR_CLEAR_TX* = 0x04'u8 # Clear transmit FIFO

  ## Interrupt Enable Register (IER)
  UART_IER_DATA* = 0x01'u8     # Enable data available interrupt
  UART_IER_EMPTY* = 0x02'u8    # Enable transmit empty interrupt

# ═══════════════════════════════════════════════════════════════════════════
# I/O Port Access Functions
# ═══════════════════════════════════════════════════════════════════════════

proc outb*(port: uint16, value: uint8) {.inline.} =
  ## Write byte to I/O port
  ## x86_64 instruction: out dx, al
  asm """
    movb %0, %%al
    movw %1, %%dx
    outb %%al, %%dx
  """ : : "r"(value), "r"(port)

proc inb*(port: uint16): uint8 {.inline.} =
  ## Read byte from I/O port
  ## x86_64 instruction: in al, dx
  var result: uint8
  asm """
    movw %1, %%dx
    inb %%dx, %%al
    movb %%al, %0
  """ : "=r"(result) : "r"(port)
  result

# ═══════════════════════════════════════════════════════════════════════════
# UART Initialization
# ═══════════════════════════════════════════════════════════════════════════

var gUartInitialized* = false

proc initializeUart*(port: uint16 = UART_COM1, baudRate: uint32 = 115200'u32) =
  ## Initialize UART 16550 for 8N1 (8 bits, no parity, 1 stop bit)
  ## at specified baud rate (default 115200)
  ##
  ## Standard initialization sequence:
  ## 1. Disable interrupts
  ## 2. Set DLAB to access divisor registers
  ## 3. Set baud rate divisor
  ## 4. Clear DLAB, set word length and stop bits
  ## 5. Setup FIFO if available
  ## 6. Set RTS/DTR signals

  # Step 1: Disable interrupts
  outb(port + UART_IER, 0x00)

  # Step 2: Set DLAB to access divisor latch
  outb(port + UART_LCR, UART_LCR_DLAB)

  # Step 3: Set baud rate (default clock is 1.8432 MHz)
  let divisor = 115200'u32 div baudRate
  outb(port + UART_DLL, uint8(divisor and 0xFF))
  outb(port + UART_DLM, uint8((divisor shr 8) and 0xFF))

  # Step 4: Clear DLAB, set to 8N1 (8 bits, no parity, 1 stop bit)
  let lcr = uint8(UART_LCR_WLS)  # 8 bits (WLS = 0x03)
  outb(port + UART_LCR, lcr)

  # Step 5: Enable FIFO if available, clear both FIFOs
  outb(port + UART_FCR, UART_FCR_ENABLE or UART_FCR_CLEAR_RX or UART_FCR_CLEAR_TX)

  # Step 6: Set output signals (RTS + DTR)
  outb(port + UART_MCR, 0x03)  # RTS and DTR high

  # Disable interrupts again (we'll use polling)
  outb(port + UART_IER, 0x00)

  gUartInitialized = true

# ═══════════════════════════════════════════════════════════════════════════
# UART Output Functions
# ═══════════════════════════════════════════════════════════════════════════

proc waitTransmitReady*(port: uint16 = UART_COM1) =
  ## Wait until UART is ready to transmit
  ## Check Line Status Register for Transmit Holding Register Empty
  var count = 0
  while count < 1000000:  # Timeout to prevent infinite loops
    let lsr = inb(port + UART_LSR)
    if (lsr and UART_LSR_THRE) != 0:
      return
    inc count
  # Timeout - just continue anyway

proc sendByte*(byte: uint8, port: uint16 = UART_COM1) =
  ## Send single byte via UART
  waitTransmitReady(port)
  outb(port + UART_THR, byte)

proc sendString*(s: cstring, port: uint16 = UART_COM1) =
  ## Send null-terminated string via UART
  var i = 0
  while s[i] != '\0':
    sendByte(uint8(s[i]), port)
    inc i

# ═══════════════════════════════════════════════════════════════════════════
# Kernel Console Output API
# ═══════════════════════════════════════════════════════════════════════════

proc kprint*(msg: string, port: uint16 = UART_COM1) =
  ## Print string to kernel console
  ## Replaces early VGA text mode output
  if not gUartInitialized:
    initializeUart(port)

  for c in msg:
    sendByte(uint8(c), port)

proc kprintln*(msg: string, port: uint16 = UART_COM1) =
  ## Print string with newline to kernel console
  kprint(msg, port)
  kprint("\n", port)

proc kprintf*(fmt: string, args: varargs[untyped], port: uint16 = UART_COM1) =
  ## Printf-style formatted output to kernel console
  let message = fmt(fmt, args)
  kprint(message, port)

proc kprintfln*(fmt: string, args: varargs[untyped], port: uint16 = UART_COM1) =
  ## Printf-style formatted output with newline
  kprintf(fmt, args, port)
  kprint("\n", port)

# ═══════════════════════════════════════════════════════════════════════════
# Convenience Macros for Debug Output
# ═══════════════════════════════════════════════════════════════════════════

template debug*(msg: string) =
  ## Debug output (compile-time controlled)
  when defined(DEBUG_CONSOLE):
    kprintln("[DEBUG] " & msg)

template info*(msg: string) =
  ## Informational output
  kprintln("[INFO] " & msg)

template warn*(msg: string) =
  ## Warning output
  kprintln("[WARN] " & msg)

template error*(msg: string) =
  ## Error output
  kprintln("[ERROR] " & msg)

# ═══════════════════════════════════════════════════════════════════════════
# Early Console Backup (VGA Text Mode - if serial fails)
# ═══════════════════════════════════════════════════════════════════════════

proc printVga*(msg: string) =
  ## Fallback VGA text mode output if serial is unavailable
  ## Writes to video memory directly
  var ptr = cast[ptr uint16](0xB8000)
  for c in msg:
    if c == '\0': break
    ptr[] = uint16(c) or 0x0F00  # White on black
    inc(ptr)

# ═══════════════════════════════════════════════════════════════════════════
# Console Initialization
# ═══════════════════════════════════════════════════════════════════════════

proc initConsole*(port: uint16 = UART_COM1) =
  ## Initialize kernel console
  ## Called from kernel_main during boot
  initializeUart(port)
  kprintln("")
  kprintln("╔════════════════════════════════════════════════════════════╗")
  kprintln("║            NimixOS Kernel - Console Initialized           ║")
  kprintln("║                  Serial UART 16550 Driver                 ║")
  kprintln("╚════════════════════════════════════════════════════════════╝")
  kprintln("")

# ═══════════════════════════════════════════════════════════════════════════
# Receiver Functions (for future use with keyboard/input)
# ═══════════════════════════════════════════════════════════════════════════

proc receiveByte*(port: uint16 = UART_COM1): Option[uint8] =
  ## Try to receive a byte from UART (non-blocking)
  ## Returns none() if no data available
  let lsr = inb(port + UART_LSR)
  if (lsr and UART_LSR_RDR) != 0:
    some(inb(port + UART_RBR))
  else:
    none(uint8)

proc receiveString*(port: uint16 = UART_COM1, maxLen: int = 256): string =
  ## Receive line from UART (blocking)
  ## Reads until newline or maxLen reached
  var result = ""
  var count = 0
  while count < maxLen:
    let byteOpt = receiveByte(port)
    if byteOpt.isSome():
      let b = byteOpt.get()
      if b == '\n'.uint8:
        break
      result.add(char(b))
      inc count
    # Simple polling with timeout
    var timeout = 0
    while timeout < 100000 and receiveByte(port).isNone():
      inc timeout
  result

# ═══════════════════════════════════════════════════════════════════════════
# Documentation & Philosophy
# ═══════════════════════════════════════════════════════════════════════════

## CONSOLE DRIVER PHILOSOPHY:
##
## This module provides a simple, standard interface to UART 16550
## which is nearly universal on x86_64 systems.
##
## Why UART?
## - Available on all PC hardware
## - Standardized (16550 compatible)
## - No IRQ needed (polling only)
## - Works from real early in boot
## - Accessible from QEMU and real hardware
##
## Why not just VGA?
## - Serial is better for remote debugging
## - Works over SSH/serial cable
## - No timing/flicker issues
## - Standard for server/embedded systems
##
## UART 16550 Compatibility:
## - This driver uses only standard registers
## - Works with 16550, 16650, 16750, etc.
## - Polling-based (no interrupts)
## - Simple and reliable
##
## BAUD RATE:
## - Default: 115200 (standard)
## - Can be configured at init time
## - Divisor calculated from base clock (1.8432 MHz)
##
## NEXT STEPS:
## - Add interrupt-driven input for keyboard
## - Add buffering for performance
## - Add different console backends (VGA, HDMI, etc.)
## - Add log levels and filtering
