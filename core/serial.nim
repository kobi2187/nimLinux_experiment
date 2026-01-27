# SPDX-License-Identifier: GPL-2.0
## Serial Console - LAYER 0
##
## Simple serial port output for debugging.
## No dependencies beyond arch primitives.

when defined(amd64) or defined(x86_64):
  import ../arch/x86_64/cpu_primitives

const
  # Serial port addresses
  COM1* = 0x3F8'u16
  COM2* = 0x2F8'u16
  COM3* = 0x3E8'u16
  COM4* = 0x2E8'u16

  # Serial port register offsets
  SerData* = 0'u16        ## Data register (read/write)
  SerIntEnable* = 1'u16   ## Interrupt enable
  SerFifoCtrl* = 2'u16    ## FIFO control
  SerLineCtrl* = 3'u16    ## Line control
  SerModemCtrl* = 4'u16   ## Modem control
  SerLineStatus* = 5'u16  ## Line status
  SerModemStatus* = 6'u16 ## Modem status
  SerScratch* = 7'u16     ## Scratch register

  # Divisor latch registers (when DLAB is set)
  SerDivisorLow* = 0'u16  ## Divisor latch low
  SerDivisorHigh* = 1'u16 ## Divisor latch high

  # Line control bits
  DLAB* = 0x80'u8         ## Divisor latch access bit

  # Line status bits
  DataReady* = 0x01'u8    ## Data ready to read
  TransEmpty* = 0x20'u8   ## Transmitter holding register empty
  TransIdle* = 0x40'u8    ## Transmitter empty

type
  SerialPort* = object
    ## Serial port state
    port*: uint16         ## Base I/O port
    initialized*: bool    ## Has been initialized

var
  # Global serial port (COM1)
  defaultSerial*: SerialPort

# ═══════════════════════════════════════════════════════════════════════════
# Low-level I/O
# ═══════════════════════════════════════════════════════════════════════════

when defined(amd64) or defined(x86_64):
  proc serialInb(port: uint16): uint8 {.inline.} = inb(port)
  proc serialOutb(port: uint16, val: uint8) {.inline.} = outb(port, val)
else:
  # Fallback for non-x86
  proc serialInb(port: uint16): uint8 = 0
  proc serialOutb(port: uint16, val: uint8) = discard

# ═══════════════════════════════════════════════════════════════════════════
# Initialization
# ═══════════════════════════════════════════════════════════════════════════

proc init*(serial: var SerialPort, port: uint16 = COM1, baud: uint32 = 115200) =
  ## Initialize serial port
  serial.port = port

  let divisor = uint16(115200 div baud)

  # Disable interrupts
  serialOutb(port + SerIntEnable, 0x00)

  # Set DLAB to access divisor
  serialOutb(port + SerLineCtrl, DLAB)

  # Set divisor (baud rate)
  serialOutb(port + SerDivisorLow, uint8(divisor and 0xFF))
  serialOutb(port + SerDivisorHigh, uint8(divisor shr 8))

  # 8 bits, no parity, 1 stop bit, clear DLAB
  serialOutb(port + SerLineCtrl, 0x03)

  # Enable FIFO, clear, 14-byte threshold
  serialOutb(port + SerFifoCtrl, 0xC7)

  # Enable DTR, RTS, OUT2
  serialOutb(port + SerModemCtrl, 0x0B)

  serial.initialized = true

proc isTransmitReady(serial: SerialPort): bool {.inline.} =
  ## Check if transmitter is ready
  (serialInb(serial.port + SerLineStatus) and TransEmpty) != 0

proc isReceiveReady(serial: SerialPort): bool {.inline.} =
  ## Check if data is ready to read
  (serialInb(serial.port + SerLineStatus) and DataReady) != 0

# ═══════════════════════════════════════════════════════════════════════════
# Output
# ═══════════════════════════════════════════════════════════════════════════

proc putChar*(serial: SerialPort, c: char) =
  ## Write a character to serial port
  if not serial.initialized:
    return

  # Wait for transmitter to be ready
  while not serial.isTransmitReady():
    discard

  serialOutb(serial.port + SerData, uint8(c))

proc putString*(serial: SerialPort, s: cstring) =
  ## Write a null-terminated string
  var i = 0
  while s[i] != '\0':
    if s[i] == '\n':
      serial.putChar('\r')
    serial.putChar(s[i])
    inc i

proc putString*(serial: SerialPort, s: string) =
  ## Write a string
  for c in s:
    if c == '\n':
      serial.putChar('\r')
    serial.putChar(c)

proc putLine*(serial: SerialPort, s: string) =
  ## Write a string with newline
  serial.putString(s)
  serial.putChar('\r')
  serial.putChar('\n')

proc putHex*(serial: SerialPort, val: uint64, width: int = 0) =
  ## Write a hex value
  const hexChars = "0123456789abcdef"
  var buf: array[16, char]
  var v = val
  var i = 0

  if v == 0:
    buf[i] = '0'
    inc i
  else:
    while v > 0:
      buf[i] = hexChars[v and 0xF]
      v = v shr 4
      inc i

  # Pad if needed
  while i < width:
    buf[i] = '0'
    inc i

  # Print in reverse
  while i > 0:
    dec i
    serial.putChar(buf[i])

proc putInt*(serial: SerialPort, val: int64) =
  ## Write a decimal integer
  if val < 0:
    serial.putChar('-')
    serial.putInt(-val)
    return

  var buf: array[20, char]
  var v = val
  var i = 0

  if v == 0:
    serial.putChar('0')
    return

  while v > 0:
    buf[i] = char(ord('0') + int(v mod 10))
    v = v div 10
    inc i

  while i > 0:
    dec i
    serial.putChar(buf[i])

# ═══════════════════════════════════════════════════════════════════════════
# Input
# ═══════════════════════════════════════════════════════════════════════════

proc getChar*(serial: SerialPort): char =
  ## Read a character from serial port (blocking)
  while not serial.isReceiveReady():
    discard
  char(serialInb(serial.port + SerData))

proc tryGetChar*(serial: SerialPort): Option[char] =
  ## Try to read a character (non-blocking)
  if serial.isReceiveReady():
    return some(char(serialInb(serial.port + SerData)))
  none(char)

# ═══════════════════════════════════════════════════════════════════════════
# Global Interface
# ═══════════════════════════════════════════════════════════════════════════

proc initSerial*() =
  ## Initialize default serial port (COM1)
  defaultSerial.init(COM1)

proc kprint*(s: string) =
  ## Print to default serial port
  defaultSerial.putString(s)

proc kprintln*(s: string) =
  ## Print line to default serial port
  defaultSerial.putLine(s)

proc kprintHex*(val: uint64) =
  ## Print hex to default serial port
  defaultSerial.putString("0x")
  defaultSerial.putHex(val)

proc kprintInt*(val: int64) =
  ## Print integer to default serial port
  defaultSerial.putInt(val)

# ═══════════════════════════════════════════════════════════════════════════
# Formatted Output (simple)
# ═══════════════════════════════════════════════════════════════════════════

proc kprintf*(fmt: string, args: varargs[string, `$`]) =
  ## Simple formatted print (no format specifiers, just concatenation)
  var argIdx = 0
  var i = 0
  while i < fmt.len:
    if fmt[i] == '{' and i + 1 < fmt.len and fmt[i + 1] == '}':
      if argIdx < args.len:
        kprint(args[argIdx])
        inc argIdx
      i += 2
    else:
      defaultSerial.putChar(fmt[i])
      if fmt[i] == '\n':
        defaultSerial.putChar('\r')
      inc i
